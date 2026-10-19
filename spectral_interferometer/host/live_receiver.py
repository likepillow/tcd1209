"""USB worker with prepared/stopped state and acknowledged graceful shutdown."""
from dataclasses import replace
import queue
import struct
import threading
import time

from protocol import Decoder, Kind, run_command
from acquisition_settings import AcquisitionSettings
from recording import Recorder
from usb_transport import CypressUSB


class USBReceiver(threading.Thread):
    ACK_TIMEOUT = 5.0

    def __init__(self, dll, display, *, record_to=None, transport_factory=CypressUSB):
        super().__init__(name='SPIF USB', daemon=True)
        self.dll, self.display, self.record_to = dll, display, record_to
        self.transport_factory = transport_factory
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

    def submit(self, packet):
        if packet.kind not in (Kind.SOURCE, Kind.K_WEIGHTS, Kind.EXPORT,
                               Kind.ACQUISITION, Kind.RUN_CONTROL):
            raise ValueError('Only configuration/run commands may be submitted')
        packet.encode()
        if not self.ready.is_set() or self.disconnect_requested.is_set():
            raise IOError('USB is not ready')
        self.commands.put_nowait((packet, 'user'))

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
        try:
            decoder = Decoder()
            if self.record_to is not None:
                recorder = Recorder(self.record_to, {'source_mode': 'USB', 'vid': '04B4', 'pid': '00F1'})
                decoder = recorder.decoder
            with self.transport_factory(self.dll) as usb:
                self.ever_connected = True
                self.connected.set()
                self.state = '连接中'
                self.display.set_status('USB 已打开，正在确认 FPGA 停止状态…')
                last_flush = time.monotonic()
                while not exit_after_ack:
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
                        nonlocal pending, exit_after_ack
                        self.display.ingest(packet)
                        if packet.kind != Kind.ACK:
                            return
                        ack_sequence, status, _ = struct.unpack('<IHH', packet.payload)
                        if pending is None or ack_sequence != pending[0].sequence:
                            raise IOError('Unexpected/stale FPGA acknowledgement; session must be resynchronized')
                        command, purpose, _ = pending
                        if status:
                            raise IOError(f'FPGA rejected command, status={status}')
                        if command.kind == Kind.ACQUISITION:
                            settings = AcquisitionSettings.decode(command.payload)
                            self.display.set_acquisition(settings)
                            if recorder is not None:
                                recorder.acquisition_applied(settings)
                            self.events.put(('acquisition', settings))
                        elif command.kind == Kind.RUN_CONTROL:
                            running = bool(struct.unpack('<I', command.payload)[0])
                            self.run_state = running
                            self.display.set_running(running)
                            if recorder is not None:
                                recorder.run_state_changed(running)
                            self.events.put(('run', running, purpose))
                            if purpose == 'initial':
                                self.ready.set()
                                self.state = 'USB 已准备/采集停止'
                                self.display.set_status('USB 已准备，FPGA 已停止；可配置或开始采集')
                            elif purpose == 'disconnect':
                                self.shutdown_confirmed.set()
                                self.state = '未连接'
                                self.display.set_status('FPGA 已安全停止并排空，USB 已断开')
                                exit_after_ack = True
                            else:
                                self.state = '采集中' if running else 'USB 已准备/采集停止'
                                self.display.set_status('采集中' if running else '采集已安全停止，配置与曲线已保留')
                        self.events.put(('ack', ack_sequence, status, packet.source_version, packet.k_version))
                        pending = None

                    if transfer.data:
                        if recorder is not None:
                            recorder.append(transfer.data, receive)
                        else:
                            for packet in decoder.feed(transfer.data):
                                receive(packet)
                    if not transfer.success and not transfer.idle_timeout:
                        raise IOError(f'USB read failed: error={transfer.error}, bytes={transfer.count}, '
                                      f'NT={transfer.nt_status:08x}, USBD={transfer.usbd_status:08x}')
                    if pending is not None and time.monotonic() > pending[2]:
                        raise TimeoutError('FPGA acknowledgement timeout; command state unknown, no retry')
                    if recorder is not None and time.monotonic()-last_flush > 1:
                        recorder.flush()
                        last_flush = time.monotonic()
                decoder.finish()
        except Exception as error:
            self.failure = str(error)
            self.state = '停机未确认'
            self.events.put(('failure', self.failure))
            self.display.set_status('USB 会话失败：'+self.failure, True)
        finally:
            self.ready.clear()
            self.connected.clear()
            if recorder is not None:
                try:
                    recorder.close(self.failure)
                except Exception as error:
                    self.failure = str(error)
                    self.events.put(('failure', self.failure))
                    self.display.set_status('USB 保存失败：'+self.failure, True)
