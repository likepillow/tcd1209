"""Timestamp-paced SPIF file replay worker."""
from pathlib import Path
import threading
import time
import json

from protocol import Decoder, Kind
from recording import Recorder
from acquisition_settings import AcquisitionSettings


class ReplayPacer:
    """Map FPGA time to wall time; changing speed re-anchors without catch-up."""
    def __init__(self, speed=1.0, period_pixels=2114, *, clock=time.monotonic):
        self._clock = clock
        self._wake = threading.Event()
        self._lock = threading.Lock()
        self._speed = None
        self._anchor_wall = None
        self._anchor_ticks = None
        self._last_ticks = None
        self._last_frame = None
        self._fallback_ticks = 0
        self._period_pixels = period_pixels
        self.estimated = False
        self.set_speed(speed)

    @property
    def speed(self):
        with self._lock:
            return self._speed

    def set_speed(self, speed):
        if speed is not None and (not isinstance(speed, (int, float)) or speed <= 0):
            raise ValueError('Replay speed must be positive or None')
        now = self._clock()
        with self._lock:
            self._speed = None if speed is None else float(speed)
            if self._last_ticks is not None:
                self._anchor_ticks = self._last_ticks
                self._anchor_wall = now
        self._wake.set()

    def set_period(self, period_pixels):
        self._period_pixels = int(period_pixels)

    def _ticks(self, packet):
        from protocol import TIME_VALID, NO_FRAME
        if packet.flags & TIME_VALID:
            return packet.timestamp
        if packet.frame_id == NO_FRAME:
            return self._last_ticks
        self.estimated = True
        if self._last_frame is None:
            self._last_frame = packet.frame_id
        elif packet.frame_id != self._last_frame:
            delta = (packet.frame_id-self._last_frame) & 0xffffffff
            if delta < 2**31:
                self._fallback_ticks += delta*self._period_pixels*20
            self._last_frame = packet.frame_id
        return self._fallback_ticks

    def pace(self, packet, stop_event):
        ticks = self._ticks(packet)
        if ticks is None:
            return
        with self._lock:
            if self._anchor_ticks is None:
                self._anchor_ticks, self._anchor_wall = ticks, self._clock()
            self._last_ticks = ticks
        while not stop_event.is_set():
            self._wake.clear()
            with self._lock:
                speed, anchor_ticks, anchor_wall = self._speed, self._anchor_ticks, self._anchor_wall
            if speed is None:
                return
            delay = anchor_wall+(ticks-anchor_ticks)/1e8/speed-self._clock()
            if delay <= 0:
                return
            self._wake.wait(min(delay, .1))


class FileReceiver(threading.Thread):
    def __init__(self, path, display, *, record_to=None, speed=1.0, result_interval=None):
        super().__init__(name='SPIF replay', daemon=True)
        self.path = Path(path)
        self.display = display
        self.record_to = record_to
        self.result_interval = result_interval
        self.pacer = ReplayPacer(speed)
        self.stop_event = threading.Event()
        self.failure = None

    def stop(self):
        self.stop_event.set()

    def set_speed(self, speed):
        self.pacer.set_speed(speed)
        label = '不限速' if speed is None else f'{speed:g}×'
        self.display.set_status(f'离线回放中：{label}；优先使用 FPGA 100 MHz 时间戳')

    def run(self):
        recorder = None
        try:
            decoder = Decoder()
            events, run_events = {}, {}
            manifest = self.path.with_name('manifest.json')
            if self.path.name == 'stream.spif' and manifest.exists():
                metadata = json.loads(manifest.read_text(encoding='utf-8')).get('metadata', {})
                for event in metadata.get('acquisition_events', []):
                    events[int(event['after_packet'])] = AcquisitionSettings(
                        int(event['window_start']), int(event['period_pixels']))
                for event in metadata.get('run_events', []):
                    run_events.setdefault(int(event['after_packet']), []).append(bool(event['running']))
            if self.record_to is not None:
                recorder = Recorder(self.record_to, {'source_mode': 'file_replay', 'source_path': str(self.path)})
                decoder = recorder.decoder
            # Events at packet zero precede the first packet. Waiting until the
            # receive callback would never apply them (its counter starts at 1),
            # giving legacy recordings the default cadence instead of their T.
            if 0 in events:
                settings = events[0]
                self.display.set_acquisition(settings)
                self.pacer.set_period(settings.period_pixels)
                if recorder is not None:
                    recorder.acquisition_applied(settings)
            for running in run_events.get(0, ()):
                self.display.set_running(running)
                if recorder is not None:
                    recorder.run_state_changed(running)
            label = '不限速' if self.pacer.speed is None else f'{self.pacer.speed:g}×'
            self.display.set_status(f'离线回放中：{label}；优先使用 FPGA 100 MHz 时间戳')

            def receive(packet):
                self.pacer.pace(packet, self.stop_event)
                if self.stop_event.is_set():
                    return
                self.display.ingest(packet)
                if decoder.packets in events:
                    settings = events[decoder.packets]
                    self.display.set_acquisition(settings)
                    self.pacer.set_period(settings.period_pixels)
                    if recorder is not None:
                        recorder.acquisition_applied(settings)
                for running in run_events.get(decoder.packets, ()):
                    self.display.set_running(running)
                    if recorder is not None:
                        recorder.run_state_changed(running)
                if packet.kind == Kind.RESULT and self.result_interval is not None and self.result_interval:
                    self.stop_event.wait(self.result_interval)

            last_flush = time.monotonic()
            with self.path.open('rb') as stream:
                while not self.stop_event.is_set():
                    chunk = stream.read(32768)
                    if not chunk:
                        break
                    if recorder is None:
                        for packet in decoder.feed(chunk):
                            receive(packet)
                    else:
                        recorder.append(chunk, receive)
                        if time.monotonic()-last_flush > 1:
                            recorder.flush()
                            last_flush = time.monotonic()
            if self.stop_event.is_set():
                self.failure = '用户停止回放，未完成全文件校验'
                self.display.set_status(self.failure)
            else:
                decoder.finish()
                state = self.display.snapshot()
                if (decoder.bad_headers or decoder.bad_crc or decoder.bad_payloads or decoder.discarded_bytes
                        or state['missing'] or state['out_of_order'] or state['discontinuities']):
                    raise ValueError(f'记录不完整：CRC={decoder.bad_crc}，非法包头={decoder.bad_headers}，'
                                     f'非法数据={decoder.bad_payloads}，丢弃字节={decoder.discarded_bytes}，'
                                     f'缺包={state["missing"]}，重复/倒序={state["out_of_order"]}，'
                                     f'设备不连续标记={state["discontinuities"]}')
                rhythm = '使用 T/frame_id 估算节奏' if self.pacer.estimated else '按 FPGA 时间戳回放'
                self.display.set_status(f'回放完成：{decoder.packets} 个包已校验；{rhythm}；设备仍未连接')
        except Exception as error:
            self.failure = str(error)
            self.display.set_status('回放/保存失败：'+self.failure, True)
        finally:
            if recorder is not None:
                try:
                    recorder.close(self.failure)
                except Exception as error:
                    self.failure = str(error)
                    self.display.set_status('记录关闭失败：'+self.failure, True)
