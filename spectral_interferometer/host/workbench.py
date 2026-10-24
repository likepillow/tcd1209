"""Thread-safe display state and local calibration editing for the host GUI."""
from collections import deque
from dataclasses import dataclass
from pathlib import Path
import threading

import numpy as np

from fixed import reciprocal_q30
from protocol import (Kind, DistanceResult, SequenceTracker, SPECTRUM_DTYPE,
                      DISCONTINUITY, TIME_VALID, INVALID, source_command, k_command, export_command)
from reference import Calibration, crop1024, load_vector, vector
from acquisition_settings import AcquisitionSettings


def immutable(values):
    result = np.array(values, copy=True)
    result.setflags(write=False)
    return result


def smooth_reference(values, width=31):
    """Optional reflected moving mean of source S; never measurement fringes."""
    if not isinstance(width, int) or width < 3 or width > 127 or width % 2 != 1:
        raise ValueError('参考S平滑宽度必须为3～127之间的奇数')
    source = crop1024(values, 'S')
    return np.convolve(np.pad(source, width//2, mode='reflect'), np.ones(width)/width, mode='valid')


class DisplayState:
    def __init__(self, history_size=4096):
        self.lock = threading.Lock()
        self.history_size = history_size
        self.reset()

    def reset(self):
        with self.lock:
            self.sequence = SequenceTracker()
            self.channels = {}
            self.acquisition = None
            self.running = None
            self.frames = {}
            self.stream_frames = {}
            self.invalid = {}
            self.history = deque(maxlen=self.history_size)
            self.result = None
            self.result_packet = None
            self.result_count = 0
            self.discontinuities = 0
            self.pending_gap = False
            self.packet_count = 0
            self.status = '未连接设备；可打开 SPIF 记录回放'
            self.error = False
            self.optical_warning = ''
            self.source_average = None
            self.completed_source_average = None
            self.revision = getattr(self, 'revision', 0)+1

    def begin_source_average(self, count=128):
        """Average future complete S0 packets; never average one frame twice."""
        count = int(count)
        if not 2 <= count <= 4096:
            raise ValueError('光源 S 平均帧数必须为 2 至 4096')
        with self.lock:
            if self.source_average is not None:
                raise ValueError('光源 S 多帧平均已在进行')
            settings = None if self.acquisition is None else (
                self.acquisition.window_start, self.acquisition.period_pixels)
            self.source_average = dict(target=count, accepted=0, rejected=0,
                                       mean=None, m2=None, first=None, last=None,
                                       last_seen=None, settings=settings)
            self.completed_source_average = None
            self.revision += 1

    def cancel_source_average(self):
        with self.lock:
            self.source_average = None
            self.completed_source_average = None
            self.revision += 1

    def take_source_average(self):
        with self.lock:
            result = self.completed_source_average
            self.completed_source_average = None
            return result

    def _source_sample(self, values, frame_id, invalid):
        job = self.source_average
        if job is None or frame_id == job['last_seen']:
            return
        job['last_seen'] = frame_id
        values = np.asarray(values, dtype=np.float64)
        # A saturated/zero or protocol-invalid frame is unsuitable as a divisor.
        if invalid or values.size != 1024 or np.any(values <= 0) or np.any(values >= 4095):
            job['rejected'] += 1
            return
        job['accepted'] += 1
        job['first'] = frame_id if job['first'] is None else job['first']
        job['last'] = frame_id
        if job['mean'] is None:
            job['mean'] = values.copy()
            job['m2'] = np.zeros_like(values)
        else:
            delta = values-job['mean']
            job['mean'] += delta/job['accepted']
            job['m2'] += delta*(values-job['mean'])
        if job['accepted'] == job['target']:
            variance = job['m2']/max(1, job['accepted']-1)
            self.completed_source_average = {
                'source': immutable(job['mean']),
                'std': immutable(np.sqrt(np.maximum(variance, 0))),
                'count': job['accepted'], 'rejected': job['rejected'],
                'first_frame': job['first'], 'last_frame': job['last'],
                'settings': job['settings']}
            self.source_average = None

    def set_status(self, text, error=False):
        with self.lock:
            self.status = text
            self.error = error
            self.revision += 1

    def set_acquisition(self, settings):
        with self.lock:
            self.acquisition = settings
            self.channels.clear()
            self.frames.clear()
            self.invalid.clear()
            self.optical_warning = ''
            self.history.clear()
            self.result = self.result_packet = None
            self.pending_gap = True
            self.source_average = None
            self.completed_source_average = None
            self.revision += 1

    def set_running(self, running):
        """Update acquisition state without discarding curves or calibration."""
        if not isinstance(running, bool):
            raise TypeError('running must be bool')
        with self.lock:
            if self.running != running:
                self.pending_gap = True
            self.running = running
            self.revision += 1

    def ingest(self, packet):
        with self.lock:
            previous_missing = self.sequence.missing
            ordered = self.sequence.observe(packet.sequence)
            self.packet_count += 1
            # Preserve the recorder's bytes, but don't move a displayed frame backward.
            if not ordered:
                self.revision += 1
                return
            gap = self.sequence.missing != previous_missing or bool(packet.flags & DISCONTINUITY)
            if packet.kind in (Kind.RAW, Kind.SPECTRUM, Kind.PHASE, Kind.RESULT):
                previous_frame = self.stream_frames.get(packet.kind)
                gap |= previous_frame is not None and ((packet.frame_id-previous_frame) & 0xffffffff) != 1
                self.stream_frames[packet.kind] = packet.frame_id
            self.discontinuities += int(bool(packet.flags & DISCONTINUITY))
            self.pending_gap |= gap
            if packet.kind == Kind.RAW:
                raw = np.frombuffer(packet.payload, '<u2')
                self.channels['S0'] = immutable(raw)
                self.frames['S0'] = packet.frame_id
                self.invalid['S0'] = bool(packet.flags & INVALID)
                clipped = int(np.count_nonzero((raw == 0) | (raw == 4095)))
                self.optical_warning = (f'S0帧{packet.frame_id}有{clipped}个0/4095钳位像素；距离即使未标无效也不可直接用于测量'
                                        if clipped else '')
                self._source_sample(raw, packet.frame_id, self.invalid['S0'])
            elif packet.kind == Kind.SPECTRUM:
                data = np.frombuffer(packet.payload, SPECTRUM_DTYPE)
                for key in ('S0', 'S1', 'S2'):
                    # Don't overwrite a newer raw frame with an older processed frame.
                    if key == 'S0' and 'S0' in self.frames:
                        delta = (packet.frame_id-self.frames['S0']) & 0xffffffff
                        if delta >= 2**31:
                            continue
                    if key == 'S0':
                        clipped = int(np.count_nonzero((data['s0'] == 0) | (data['s0'] == 4095)))
                        self.optical_warning = (f'S0帧{packet.frame_id}有{clipped}个0/4095钳位像素；距离不可直接用于测量'
                                                if clipped else '')
                    self.channels[key] = immutable(data[key.lower()] if key == 'S0' else data[key.lower()]/4096.)
                    self.frames[key] = packet.frame_id
                    self.invalid[key] = bool(packet.flags & INVALID)
                if self.frames.get('S0') == packet.frame_id:
                    self._source_sample(data['s0'], packet.frame_id, bool(packet.flags & INVALID))
            elif packet.kind == Kind.PHASE:
                self.channels['P1'] = immutable(np.frombuffer(packet.payload, '<i8')*(np.pi/2**31))
                self.frames['P1'] = packet.frame_id
                self.invalid['P1'] = bool(packet.flags & INVALID)
            elif packet.kind == Kind.RESULT:
                gap |= self.pending_gap
                result = DistanceResult.from_packet(packet)
                timestamp = packet.timestamp if packet.flags & TIME_VALID else None
                versions = (packet.source_version, packet.k_version)
                if self.result_packet is not None:
                    previous = (self.result_packet.source_version, self.result_packet.k_version)
                    gap |= versions != previous
                self.history.append((self.result_count, timestamp, result.distance, gap))
                self.result_count += 1
                self.result = result
                self.result_packet = packet
                self.pending_gap = False
            self.revision += 1

    def snapshot(self):
        with self.lock:
            average = None if self.source_average is None else {
                key: self.source_average[key] for key in ('target', 'accepted', 'rejected')}
            return {'channels': dict(self.channels), 'frames': dict(self.frames),
                    'acquisition': self.acquisition,
                    'running': self.running,
                    'invalid': dict(self.invalid),
                    'history': tuple(self.history), 'result': self.result, 'result_packet': self.result_packet,
                    'packet_count': self.packet_count, 'result_count': self.result_count,
                    'missing': self.sequence.missing, 'out_of_order': self.sequence.out_of_order,
                    'discontinuities': self.discontinuities,
                    'source_average': average,
                    'optical_warning': self.optical_warning,
                    'status': self.status, 'error': self.error, 'revision': self.revision}


def trend(history):
    """Return x/y with NaN breaks; never invent hardware time when absent."""
    if not history:
        return np.array([]), np.array([]), '硬件相对时间 / s'
    times = [point[1] for point in history]
    timed = all(t is not None for t in times)
    timed = timed and all(b >= a for a, b in zip(times, times[1:]))
    x, y = [], []
    for ordinal, timestamp, distance, gap in history:
        position = (timestamp-times[0])/1e8 if timed else ordinal
        if gap and x:
            x.append(position)
            y.append(float('nan'))
        x.append(position)
        y.append(distance)
    return np.asarray(x), np.asarray(y), '硬件相对时间 / s' if timed else '结果序号（无统一硬件时间）'


@dataclass
class LocalCalibration:
    source: object = None
    k: object = None
    scale: float = 1.
    k_units: str = '未指定'
    source_origin: str = ''
    k_origin: str = ''
    window_start: int = 512
    period_pixels: int = 2114
    source_original: object = None
    source_original_origin: str = ''
    pixel_ticks: int = 20

    def __post_init__(self):
        AcquisitionSettings(self.window_start, self.period_pixels, self.pixel_ticks)

    def matches(self, settings):
        return (self.window_start, self.period_pixels, self.pixel_ticks) == (
            settings.window_start, settings.period_pixels, settings.pixel_ticks)

    def set_source(self, values, origin=''):
        source = crop1024(values, 'S', self.window_start)
        reciprocal_q30(source)  # same representability checks as uploaded coefficients
        if np.any(source > 4095):
            raise ValueError('S 超过 12 位 ADC 范围')
        self.source = immutable(source)
        self.source_origin = origin
        self.source_original = None
        self.source_original_origin = ''

    def smooth_source(self, width=31):
        if self.source is None:
            raise ValueError('请先采集或导入光源S')
        original = self.source if self.source_original is None else self.source_original
        origin = self.source_origin if self.source_original is None else self.source_original_origin
        filtered = smooth_reference(original, width)
        self.set_source(filtered, f'{origin}；参考S {width}点反射边界滑动平均')
        self.source_original = immutable(original)
        self.source_original_origin = origin

    def restore_source(self):
        if self.source_original is None:
            raise ValueError('当前S没有平滑前的原始备份')
        self.set_source(self.source_original, self.source_original_origin)

    def set_k(self, values, origin=''):
        k = vector(values, (512, 1024, 2048), 'K')
        # Validate the ENTIRE user vector, including outside the final fit crop.
        d = np.diff(k)
        if not (np.all(d > 0) or np.all(d < 0)):
            raise ValueError('K 必须严格单调，且所有值有限')
        Calibration.create(np.ones(1024), k, distance_scale=self.scale, window_start=self.window_start)
        self.k = immutable(k)
        self.k_origin = origin

    def build(self):
        if self.source is None or self.k is None:
            raise ValueError('请先配置 S 和 K')
        return Calibration.create(self.source, self.k, distance_scale=self.scale, window_start=self.window_start)

    def save(self, path):
        self.build()
        # Keep full imported K and provenance; loading does not claim FPGA applied it.
        with Path(path).open('wb') as stream:
            np.savez_compressed(stream, source=self.source, k=self.k, distance_scale=self.scale,
                                k_units=self.k_units, source_origin=self.source_origin, k_origin=self.k_origin,
                                window_start=self.window_start, period_pixels=self.period_pixels,
                                pixel_ticks=self.pixel_ticks,
                                source_original=np.array([]) if self.source_original is None else self.source_original,
                                source_original_origin=self.source_original_origin)

    @classmethod
    def load(cls, path):
        with np.load(path, allow_pickle=False) as data:
            result = cls(scale=float(data['distance_scale']),
                         window_start=int(data['window_start']) if 'window_start' in data else 512,
                         period_pixels=int(data['period_pixels']) if 'period_pixels' in data else 2114,
                         pixel_ticks=int(data['pixel_ticks']) if 'pixel_ticks' in data else 20,
                         k_units=str(data['k_units']) if 'k_units' in data else '未指定')
            result.set_source(data['source'], str(data['source_origin']) if 'source_origin' in data else str(path))
            if 'source_original' in data and data['source_original'].size:
                original = crop1024(data['source_original'], 'original S', result.window_start)
                reciprocal_q30(original)
                if np.any(original > 4095):
                    raise ValueError('原始参考S超过ADC范围')
                result.source_original = immutable(original)
                result.source_original_origin = str(data['source_original_origin']) if 'source_original_origin' in data else str(path)
            result.set_k(data['k'] if 'k' in data else data['k_fit'],
                         str(data['k_origin']) if 'k_origin' in data else str(path))
            result.build()
            return result

    def commands(self, export_period=None):
        cal = self.build()
        data = source_command(cal.source, 0).encode()+k_command(cal, 1).encode()
        if export_period is not None:
            data += export_command(export_period, 2).encode()
        return data


def load_text(path):
    return load_vector(path)
