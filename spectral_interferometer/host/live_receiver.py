"""USB worker with prepared/stopped state and acknowledged graceful shutdown."""
from dataclasses import replace
import queue
import struct
import threading
import time

from protocol import Decoder, Kind, run_command
from acquisition_settings import AcquisitionSettings
from session_recording import AsyncSessionRecorder
from receive_pipeline import ReceivePipeline
from usb_transport import CypressUSB


class USBReceiver(threading.Thread):
    ACK_TIMEOUT = 5.0

    def __init__(self, dll, display, *, record_to=None, transport_factory=CypressUSB,
                 recording_options=None, recording_metadata=None):
        super().__init__(name='SPIF USB', daemon=True)
        self.dll, self.display, self.record_to = dll, display, record_to
        self.transport_factory = transport_factory
        self.recording_options = dict(recording_options or {})
        self.recording_metadata = dict(recording_metadata or {})
        self.commands = queue.Queue(maxsize=16)
        self.events = queue.Queue()
        self.failure = None
        self.connected = threading.Event()
        self.ever_connected = False
        self.ready = threading.Event()
        self.disconnect_requested = threading.Event()
        self.shutdown_confirmed = threading.Event()
        self.run_state = None
        self.state = '未连接'

    def submit(self, packet, calibration_metadata=None):
        if packet.kind not in (Kind.SOURCE, Kind.K_WEIGHTS, Kind.EXPORT,
                                Kind.ACQUISITION, Kind.EXPOSURE, Kind.RUN_CONTROL):
            raise ValueError('Only configuration/run commands may be submitted')
        packet.encode()
        if not self.ready.is_set() or self.disconnect_requested.is_set():
            raise IOError('USB is not ready')
        self.commands.put_nowait((packet, calibration_metadata if calibration_metadata is not None else 'user'))

    def start_acquisition(self):
        self.submit(run_command(True, 0))

    def stop_acquisition(self):
        self.submit(run_command(False, 0))

    def request_disconnect(self):
        self.state = '断开中'
        self.disconnect_requested.set()

    def stop(self):
        """Compatibility alias: always request the safe STOP/ACK path."""
        self.request_disconnect()

    def _discard_unsent(self):
        while True:
            try:
                self.commands.get_nowait()
            except queue.Empty:
                return

    def run(self):
        recorder = None
        pending = None
        sequence = 0
        initial_stop_sent = False
        exit_after_ack = False
        recording_error = None
        backlog_warned = False
        stop_reason = 'user_disconnect'
        disk_stop = None
        try:
            decoder = Decoder()
            if self.record_to is not None:
                recorder = AsyncSessionRecorder(self.record_to,
                    {**self.recording_metadata, 'source_mode': 'USB', 'vid': '04B4', 'pid': '00F1'},
                    **self.recording_options)
            with ReceivePipeline(self.transport_factory, self.dll, recorder) as usb:
                self.ever_connected = True
                self.connected.set()
                self.state = '连接中'
                self.display.set_status('USB 已打开，正在确认 FPGA 停止状态…')
                while not exit_after_ack:
                    if disk_stop is not None and disk_stop.is_set():
                        disk_stop = None
                        self.ready.set()
                        self.state = 'USB 已准备/采集停止'
                        self.events.put(('run', False, 'user'))
                        self.display.set_status('采集已停止，磁盘已同步，配置与曲线已保留')
                    if usb.stop_requested.is_set():
                        stop_reason = 'receive_backlog'
                        recording_error = recording_error or usb.recording_error
                        self.disconnect_requested.set()
                    if recorder is not None:
                        if recorder.warning.is_set() and not backlog_warned:
                            backlog_warned = True
                            self.events.put(('recording_warning', recorder.metrics()))
                            self.display.set_status('磁盘队列超过75%；达到90%将自动停止并排空', True)
                        if recorder.stop_requested.is_set():
                            stop_reason = 'recording_failure' if recorder.failure or recording_error else 'disk_backlog'
                            recording_error = recording_error or recorder.failure
                            self.disconnect_requested.set()
                    if self.disconnect_requested.is_set():
                        self._discard_unsent()
                    if pending is None:
                        item = None
                        if not initial_stop_sent:
                            item = (run_command(False, 0), 'initial')
                            initial_stop_sent = True
                        elif self.disconnect_requested.is_set():
                            item = (run_command(False, 0), 'disconnect')
                        else:
                            try:
                                item = self.commands.get_nowait()
                            except queue.Empty:
                                pass
                        if item is not None:
                            command, purpose = item
                            command = replace(command, sequence=sequence)
                            sequence = (sequence+1) & 0xffffffff
                            wire = command.encode()
                            result = usb.write(wire)
                            if not result.success or result.count != len(wire):
                                raise IOError(f'USB command write uncertain: {result.count}/{len(wire)}, error={result.error}; no retry')
                            pending = (command, purpose, time.monotonic()+self.ACK_TIMEOUT)
                            if command.kind == Kind.RUN_CONTROL:
                                desired = bool(struct.unpack('<I', command.payload)[0])
                                self.state = ('启动中' if desired else
                                              ('断开中' if purpose == 'disconnect' else '停止中'))
                            self.events.put(('sent', command.sequence, command.kind, purpose))
                    transfer = usb.read()

                    def receive(packet):
                        nonlocal pending, exit_after_ack, disk_stop
                        try:
                            self.display.ingest(packet)
                        except Exception as error:
                            recording_error_handler(error)
                        if packet.kind != Kind.ACK:
                            return
                        ack_sequence, status, _ = struct.unpack('<IHH', packet.payload)
                        if pending is None or ack_sequence != pending[0].sequence:
                            raise IOError('Unexpected/stale FPGA acknowledgement; session must be resynchronized')
                        command, purpose, _ = pending
                        if status:
                            raise IOError(f'FPGA rejected command, status={status}')
                        if recorder is not None:
                            try:
                                recorder.event(dict(type='configuration', after_packet=decoder.packets,
                                    kind=int(command.kind), sequence=command.sequence,
                                    payload_hex=command.payload.hex(), source_version=packet.source_version,
                                    k_version=packet.k_version,
                                    calibration=purpose if isinstance(purpose, dict) else None))
                            except (OSError, BufferError) as error:
                                recording_error_handler(error)
                        if command.kind in (Kind.ACQUISITION, Kind.EXPOSURE):
                            settings = AcquisitionSettings.decode(command.payload)
                            self.display.set_acquisition(settings)
                            if recorder is not None:
                                record_event(dict(type='acquisition', window_start=settings.window_start,
                                    period_pixels=settings.period_pixels, pixel_ticks=settings.pixel_ticks,
                                    result_stride=settings.result_stride))
                            self.events.put(('acquisition', settings))
                        elif command.kind == Kind.RUN_CONTROL:
                            running = bool(struct.unpack('<I', command.payload)[0])
                            self.run_state = running
                            self.display.set_running(running)
                            if recorder is not None:
                                record_event(dict(type='run', running=running))
                            if not (recorder is not None and not running and purpose == 'user'):
                                self.events.put(('run', running, purpose))
                            if purpose == 'initial':
                                self.ready.set()
                                self.state = 'USB 已准备/采集停止'
                                self.display.set_status('USB 已准备，FPGA 已停止；可配置或开始采集')
                            elif purpose == 'disconnect':
                                self.shutdown_confirmed.set()
                                self.state = '磁盘排空中'
                                self.display.set_status('FPGA 已停止并排空，正在完成磁盘保存…')
                                exit_after_ack = True
                            else:
                                self.state = '采集中' if running else 'USB 已准备/采集停止'
                                self.display.set_status('采集中' if running else '采集已安全停止，配置与曲线已保留')
                                if recorder is not None and not running:
                                    try:
                                        self.ready.clear()
                                        disk_stop = recorder.checkpoint_async()
                                        self.state = '磁盘保存中'
                                        self.display.set_status('设备已停止，等待磁盘同步…')
                                    except (OSError, BufferError) as error:
                                        recording_error_handler(error)
                        self.events.put(('ack', ack_sequence, status, packet.source_version, packet.k_version))
                        pending = None

                    def recording_error_handler(error):
                        nonlocal recording_error, stop_reason
                        recording_error = recording_error or str(error)
                        stop_reason = 'recording_failure'
                        self.disconnect_requested.set()

                    def record_event(value):
                        value['after_packet'] = decoder.packets
                        try:
                            recorder.event(value)
                        except (OSError, BufferError) as error:
                            recording_error_handler(error)

                    if transfer.data:
                        for packet in decoder.feed(transfer.data):
                            receive(packet)
                    if not transfer.success and not transfer.idle_timeout:
                        raise IOError(f'USB read failed: error={transfer.error}, bytes={transfer.count}, '
                                      f'NT={transfer.nt_status:08x}, USBD={transfer.usbd_status:08x}')
                    if pending is not None and time.monotonic() > pending[2]:
                        raise TimeoutError('FPGA acknowledgement timeout; command state unknown, no retry')
                decoder.finish()
                if recording_error:
                    raise OSError(recording_error)
        except Exception as error:
            self.failure = str(error)
            self.state = '已停机/保存失败' if self.shutdown_confirmed.is_set() else '停机未确认'
            self.events.put(('failure', self.failure))
            self.display.set_status('USB 会话失败：'+self.failure, True)
        finally:
            self.ready.clear()
            self.connected.clear()
            if recorder is not None:
                try:
                    recorder.close(self.failure, device_stop_confirmed=self.shutdown_confirmed.is_set(),
                                   stop_reason=stop_reason)
                except Exception as error:
                    self.failure = str(error)
                    self.events.put(('failure', self.failure))
                    self.display.set_status('USB 保存失败：'+self.failure, True)
            if self.shutdown_confirmed.is_set() and self.failure is None:
                self.state = '未连接'
                self.display.set_status('FPGA 已安全停止，磁盘已排空并保存，USB 已断开')
