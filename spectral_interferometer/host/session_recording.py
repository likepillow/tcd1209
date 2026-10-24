"""SPIF session container v2. The wire bytes remain SPIF v1.

One disk worker owns the files. JSONL index/events are append-only and bounded
checkpoints refer only to fsynced prefixes. No raw data is rewritten on recovery.
"""
from collections import deque
from datetime import datetime, timezone
from pathlib import Path
import csv
import hashlib
import json
import os
import math
import threading
import time

from protocol import (Decoder, DistanceResult, Kind, SequenceTracker, TIME_VALID,
                      DISCONTINUITY, INVALID)

DATA_KINDS = (Kind.RAW, Kind.SPECTRUM, Kind.PHASE, Kind.RESULT)


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    with temporary.open('w', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def extend_counter(value, high, bits):
    if high is None:
        return value
    modulus = 1 << bits
    delta = (value - high % modulus) % modulus
    if delta >= modulus // 2:
        delta -= modulus
    return high + delta


class StreamAudit:
    """Per-kind counts; missing frame IDs are not silently called packet loss.

    Strides and start/stop boundaries can be intentional, so these are explicitly
    'unobserved frame IDs'. Physical starts cannot be proven by old firmware.
    """
    def __init__(self):
        self.sequence = SequenceTracker()
        self.streams = {}
        self.frame_high = self.time_high = None
        self.discontinuities = 0
        self.first = self.last = None
        self.max_device_dropped = self.max_device_malformed = 0

    def observe(self, packet):
        self.sequence.observe(packet.sequence)
        self.discontinuities += bool(packet.flags & DISCONTINUITY)
        frame = ticks = None
        if packet.kind in DATA_KINDS:
            frame = extend_counter(packet.frame_id, self.frame_high, 32)
            self.frame_high = max(frame, self.frame_high if self.frame_high is not None else frame)
            if packet.flags & TIME_VALID:
                ticks = extend_counter(packet.timestamp, self.time_high, 64)
                self.time_high = max(ticks, self.time_high if self.time_high is not None else ticks)
            entry = self.streams.setdefault(packet.kind.name, dict(
                packets=0, unique_forward_frames=0, invalid=0, unobserved_frame_ids=0,
                duplicate_or_backward=0, first_frame=frame, last_frame=None))
            entry['packets'] += 1
            entry['invalid'] += bool(packet.flags & INVALID)
            previous = entry['last_frame']
            if previous is None or frame > previous:
                entry['unique_forward_frames'] += 1
                if previous is not None:
                    entry['unobserved_frame_ids'] += frame - previous - 1
                entry['last_frame'] = frame
            else:
                entry['duplicate_or_backward'] += 1
        point = dict(sequence=packet.sequence, frame=frame, ticks=ticks, kind=int(packet.kind))
        if self.first is None:
            self.first = point
        self.last = point
        if packet.kind == Kind.RESULT:
            result = DistanceResult.from_packet(packet)
            self.max_device_dropped = max(self.max_device_dropped, result.dropped_frames)
            self.max_device_malformed = max(self.max_device_malformed, result.malformed_frames)
        return frame, ticks

    def summary(self, decoder):
        transport_ok = not any((decoder.bad_headers, decoder.bad_crc, decoder.bad_payloads,
                                decoder.discarded_bytes, len(decoder.buffer),
                                self.sequence.missing, self.sequence.out_of_order, self.discontinuities))
        return dict(packets=decoder.packets, bad_headers=decoder.bad_headers,
                    bad_crc=decoder.bad_crc, bad_payloads=decoder.bad_payloads,
                    discarded_bytes=decoder.discarded_bytes, trailing_bytes=len(decoder.buffer),
                    missing_packets=self.sequence.missing, out_of_order_packets=self.sequence.out_of_order,
                    discontinuity_packets=self.discontinuities, streams=self.streams,
                    first_packet=self.first, last_packet=self.last,
                    transport_integrity_ok=transport_ok, physical_started_lines=None,
                    all_physical_lines_saved=None,
                    max_device_dropped_frames=self.max_device_dropped,
                    max_device_malformed_frames=self.max_device_malformed,
                    physical_count_note='Wire v1 has no authoritative physical-line start/end counters; '
                                        'per-stream gaps include intentional output strides and stops.')


class SessionWriter:
    """Synchronous file owner, normally called only by AsyncSessionRecorder."""
    def __init__(self, directory, metadata=None, *, volume_bytes=1 << 30, index_interval=4096):
        if volume_bytes < 1 or index_interval < 1:
            raise ValueError('volume_bytes and index_interval must be positive')
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=False)
        self.metadata = dict(metadata or {})
        self.metadata_hash = hashlib.sha256(json.dumps(self.metadata, sort_keys=True,
            allow_nan=False).encode('utf-8')).hexdigest()
        self.software_hashes = {name: hashlib.sha256(Path(__file__).with_name(name).read_bytes()).hexdigest()
                               for name in ('protocol.py', 'session_recording.py', 'live_receiver.py')
                               if Path(__file__).with_name(name).is_file()}
        self.target = volume_bytes
        self.index_interval = index_interval
        self.decoder, self.audit = Decoder(), StreamAudit()
        self.received_bytes = self.written_bytes = self.last_complete = 0
        self.volumes = []
        self.closed = False
        self.error = None
        self.started_utc = datetime.now(timezone.utc).isoformat()
        self.anchor = None
        self.config_version = 0
        self.event_count = 0
        self.range_block = None
        self.range_count = 0
        self._files = []
        self._raw = None
        self.rotate_pending = False
        try:
            self._index = self._open('index.jsonl', 'xb')
            self._events = self._open('events.jsonl', 'xb')
            self._csv_file = self._open('distance.csv', 'x', newline='', encoding='utf-8')
            self._csv = csv.writer(self._csv_file)
            self._csv.writerow(['sequence', 'frame_id', 'extended_frame_id', 'timestamp_ticks',
                                'extended_ticks', 'source_version', 'k_version', 'flags', 'invalid',
                                'accumulator', 'exponent', 'distance', 'dropped_frames', 'malformed_frames'])
            self._new_volume()
            self.checkpoint()
        except BaseException:
            self._close_files()
            raise

    def _open(self, name, mode, **kwargs):
        stream = (self.directory / name).open(mode, **kwargs)
        self._files.append(stream)
        return stream

    def _new_volume(self):
        if self._raw is not None:
            self._raw.flush()
            os.fsync(self._raw.fileno())
            self._raw.close()
            self._files.remove(self._raw)
        name = f'stream-{len(self.volumes):05d}.spif'
        self._raw = self._open(name, 'xb')
        self._hash = hashlib.sha256()
        self.volumes.append(dict(name=name, start=self.written_bytes, bytes=0, sha256=None))
        self.rotate_pending = False

    def _write_raw(self, data):
        if not data:
            return
        if self.rotate_pending:
            self._new_volume()
        count = self._raw.write(data)
        if count != len(data):
            raise OSError(f'Short disk write: {count}/{len(data)}')
        self._hash.update(data)
        self.written_bytes += count
        self.volumes[-1]['bytes'] += count

    def _jsonline(self, stream, value):
        data = (json.dumps(value, ensure_ascii=False, allow_nan=False) + '\n').encode('utf-8')
        if stream.write(data) != len(data):
            raise OSError('Short metadata write')

    def append(self, chunk):
        if self.closed:
            raise ValueError('Recording is closed')
        base = self.received_bytes
        self.received_bytes += len(chunk)
        cursor = 0
        try:
            for packet in self.decoder.feed(chunk):
                end = self.decoder.consumed_bytes - base
                # Prefix may have been written by earlier chunks. A split only
                # occurs after a verified packet, never at an arbitrary USB cut.
                self._write_raw(memoryview(chunk)[cursor:end])
                cursor = end
                volume = self.volumes[-1]
                before = dict(frame_high=self.audit.frame_high, time_high=self.audit.time_high)
                frame, ticks = self.audit.observe(packet)
                if self.anchor is None and ticks is not None:
                    self.anchor = dict(utc=datetime.now(timezone.utc).isoformat(), ticks=ticks,
                                       uncertainty='Host receipt time, not synchronized exposure UTC')
                self.last_complete = self.decoder.consumed_bytes
                if self.range_block is None:
                    self.range_block = dict(volume=len(self.volumes)-1,
                        offset=self.decoder.packet_offset-volume['start'],
                        absolute_offset=self.decoder.packet_offset, packet_index=self.decoder.packets,
                        frame_min=None, frame_max=None, ticks_min=None, ticks_max=None, **before)
                for name, value in (('frame', frame), ('ticks', ticks)):
                    if value is not None:
                        low, high = self.range_block[name+'_min'], self.range_block[name+'_max']
                        self.range_block[name+'_min'] = value if low is None else min(low, value)
                        self.range_block[name+'_max'] = value if high is None else max(high, value)
                self.range_block['end_absolute'] = self.last_complete
                self.range_count += 1
                if self.range_count >= self.index_interval:
                    self._jsonline(self._index, dict(range=self.range_block))
                    self.range_block, self.range_count = None, 0
                if ((self.decoder.packets - 1) % self.index_interval == 0
                        or packet.kind not in DATA_KINDS):
                    self._jsonline(self._index, dict(volume=len(self.volumes)-1,
                        offset=self.decoder.packet_offset-volume['start'],
                        absolute_offset=self.decoder.packet_offset, packet_index=self.decoder.packets,
                        frame=frame, ticks=ticks, kind=int(packet.kind),
                        source_version=packet.source_version, k_version=packet.k_version,
                        event_cursor=self.event_count, **before))
                if packet.kind == Kind.RESULT:
                    result = DistanceResult.from_packet(packet)
                    self._csv.writerow([packet.sequence, packet.frame_id, frame,
                        packet.timestamp if ticks is not None else '', ticks,
                        packet.source_version, packet.k_version, packet.flags, int(result.invalid),
                        result.accumulator, result.exponent, '' if result.invalid else result.distance,
                        result.dropped_frames, result.malformed_frames])
                if volume['bytes'] >= self.target:
                    volume['sha256'] = self._hash.hexdigest()
                    self.rotate_pending = True
        finally:
            # Even a semantic/analysis exception must preserve the received tail.
            self._write_raw(memoryview(chunk)[cursor:])

    def event(self, event):
        value = dict(event)
        value.setdefault('after_packet', self.decoder.packets)
        value['event_id'] = self.event_count
        value['recorded_utc'] = datetime.now(timezone.utc).isoformat()
        if value.get('type') in ('configuration', 'acquisition'):
            self.config_version += 1
        value['config_version'] = self.config_version
        for key in ('calibration', 'dark_field'):
            if value.get(key) is not None:
                encoded = json.dumps(value[key], sort_keys=True, allow_nan=False).encode('utf-8')
                value[key+'_sha256'] = hashlib.sha256(encoded).hexdigest()
        if value.get('payload_hex'):
            value['payload_sha256'] = hashlib.sha256(bytes.fromhex(value['payload_hex'])).hexdigest()
        self._jsonline(self._events, value)
        self.event_count += 1
        self._jsonline(self._index, dict(event_id=value['event_id'],
            after_packet=value['after_packet'], volume=len(self.volumes)-1,
            offset=self.volumes[-1]['bytes'], config_version=self.config_version))

    def checkpoint(self, *, clean=False, error=None, extra=None):
        for stream in self._files:
            if not stream.closed:
                stream.flush()
                os.fsync(stream.fileno())
        self.volumes[-1]['sha256'] = self._hash.hexdigest()
        summary = self.audit.summary(self.decoder)
        summary['transport_integrity_ok'] &= clean and error is None
        status = dict(format='SPIF session', container_version=2, wire_version=1,
            started_utc=self.started_utc, timezone='Asia/Shanghai', clock_hz=100_000_000,
            frame_counter_bits=32, timestamp_counter_bits=64, first_utc_anchor=self.anchor,
            software_version='sdpm-d1-v2', device_identity=self.metadata.get('device_identity'),
            software_source_sha256=self.software_hashes,
            firmware_version=self.metadata.get('firmware_version'),
            metadata=self.metadata, metadata_sha256=self.metadata_hash, closed_cleanly=clean, error=error,
            received_bytes=self.received_bytes, committed_bytes=self.written_bytes,
            last_complete_packet_end=self.last_complete, volumes=self.volumes,
            index_bytes=self._index.tell(), event_bytes=self._events.tell(),
            event_count=self.event_count, index_interval=self.index_interval,
            tail_range=self.range_block,
            calibration_note='Acknowledged full command payloads and supplied calibration copies are in events.jsonl; '
                             'unprovided dark field/device identity/firmware remain unknown.',
            **summary)
        status.update(extra or {})
        atomic_json(self.directory/'manifest.json', status)

    def _close_files(self):
        for stream in self._files:
            try:
                stream.close()
            except OSError:
                pass

    def close(self, error=None, extra=None):
        if self.closed:
            return
        try:
            if self.decoder.buffer and error is None:
                error = f'Incomplete/trailing data: {len(self.decoder.buffer)} bytes'
            self.checkpoint(clean=error is None, error=error, extra=extra)
        finally:
            self.closed = True
            self._close_files()


class AsyncSessionRecorder:
    """Byte-budgeted FIFO, including the in-flight disk operation.

    At 90% request STOP; the remaining 10% is a drain reserve, not a guarantee
    about hardware latency. Queue exhaustion raises instead of dropping old data.
    """
    def __init__(self, directory, metadata=None, *, queue_bytes=256 << 20,
                 volume_bytes=1 << 30, index_interval=4096, writer_factory=SessionWriter):
        if queue_bytes < 1:
            raise ValueError('queue_bytes must be positive')
        self.budget = queue_bytes
        self.writer = writer_factory(directory, metadata, volume_bytes=volume_bytes,
                                     index_interval=index_interval)
        self.pending = deque()
        self.condition = threading.Condition()
        self.queued_bytes = self.peak_bytes = self.accepted_bytes = self.unsaved_bytes = 0
        self.stop_requested = threading.Event()
        self.warning = threading.Event()
        self.failure = None
        self.closing = False
        self.final_error = None
        self.final_extra = {}
        self.pressure_accepted_bytes = self.pressure_time = self.pressure_free_bytes = None
        self.worker = threading.Thread(target=self._run, name='SPIF disk', daemon=True)
        self.worker.start()

    def _enqueue(self, kind, value, cost):
        with self.condition:
            if self.failure:
                if kind == 'raw':
                    self.unsaved_bytes += cost
                raise OSError(self.failure)
            if self.closing:
                raise ValueError('Recording is closed')
            if self.queued_bytes + cost > self.budget:
                self.stop_requested.set()
                if kind == 'raw':
                    self.unsaved_bytes += cost
                self.final_error = 'Disk queue capacity exceeded; incoming bytes could not be saved'
                raise BufferError(self.final_error)
            self.pending.append((kind, value, cost))
            self.queued_bytes += cost
            self.peak_bytes = max(self.peak_bytes, self.queued_bytes)
            if kind == 'raw':
                self.accepted_bytes += cost
            if self.queued_bytes >= self.budget * .75:
                self.warning.set()
            if self.queued_bytes >= self.budget * .90:
                if self.pressure_time is None:
                    self.pressure_time = time.monotonic()
                    self.pressure_accepted_bytes = self.accepted_bytes
                    self.pressure_free_bytes = self.budget-self.queued_bytes
                self.stop_requested.set()
            self.condition.notify()

    def append(self, chunk):
        self._enqueue('raw', bytes(chunk), len(chunk))

    def event(self, value):
        # Serialize now: later GUI mutations cannot change an acknowledged copy.
        payload = json.dumps(value, ensure_ascii=False, allow_nan=False)
        self._enqueue('event', payload, len(payload.encode('utf-8')))

    def checkpoint_async(self):
        completed = threading.Event()
        self._enqueue('checkpoint', completed, 128)
        return completed

    def _run(self):
        deadline = time.monotonic() + 1
        item = None
        try:
            while True:
                with self.condition:
                    if not self.pending and not self.closing:
                        self.condition.wait(max(0, deadline-time.monotonic()))
                    item = self.pending.popleft() if self.pending else None
                    done = self.closing and item is None
                if done:
                    break
                if item is not None:
                    kind, value, cost = item
                    if kind == 'raw':
                        self.writer.append(value)
                    elif kind == 'checkpoint':
                        self.writer.checkpoint(extra=self.metrics())
                        value.set()
                    else:
                        self.writer.event(json.loads(value))
                    with self.condition:
                        self.queued_bytes -= cost
                    item = None
                if time.monotonic() >= deadline:
                    self.writer.checkpoint(extra=self.metrics())
                    deadline = time.monotonic() + 1
            self.writer.close(self.final_error, {**self.metrics(), **self.final_extra})
        except Exception as error:
            self.failure = f'{type(error).__name__}: {error}'
            self.stop_requested.set()
            try:
                with (self.writer.directory/'uncommitted-receive.bin').open('xb') as salvage:
                    if item is not None and item[0] == 'raw':
                        salvage.write(item[1])
                    for kind, value, _ in self.pending:
                        if kind == 'raw':
                            salvage.write(value)
                    salvage.flush()
                    os.fsync(salvage.fileno())
            except OSError:
                pass
            # Keep the unprocessed FIFO in memory until the receiver has stopped;
            # a failed/full disk cannot be promised to retain bytes it rejects.
            try:
                self.writer.close(self.failure, self.metrics())
            except Exception:
                self.writer._close_files()

    def metrics(self):
        tail = None if self.pressure_time is None else self.accepted_bytes-self.pressure_accepted_bytes
        return dict(queue_budget_bytes=self.budget, peak_queue_bytes=self.peak_bytes,
                    pending_queue_bytes=self.queued_bytes, accepted_bytes=self.accepted_bytes,
                    unsaved_incoming_bytes=self.unsaved_bytes,
                    stop_requested_for_backlog=self.stop_requested.is_set(),
                    bytes_received_after_pressure_stop=tail,
                    free_bytes_at_pressure_stop=self.pressure_free_bytes,
                    observed_minimum_budget_for_10_percent_reserve=None if tail is None else math.ceil(tail/.1),
                    reserve_note='Observed tail only; disk/USB stall and longest exposure must be measured on hardware.')

    def close(self, error=None, *, device_stop_confirmed=None, stop_reason=None):
        with self.condition:
            self.closing = True
            self.final_error = error or self.final_error
            self.final_extra = dict(device_stop_confirmed=device_stop_confirmed, stop_reason=stop_reason)
            self.condition.notify()
        self.worker.join()
        if self.failure:
            # A small sidecar is best effort if the main disk has failed. The
            # previous atomic manifest remains the authoritative committed prefix.
            try:
                atomic_json(self.writer.directory/'failure.json', dict(error=self.failure,
                    **self.metrics(), **self.final_extra))
            except OSError:
                pass
            raise OSError(self.failure)


def session_directory(path):
    path = Path(path)
    if path.is_dir():
        return path
    if path.name == 'manifest.json' or path.name.startswith('stream-'):
        return path.parent
    return None


def load_manifest(path):
    directory = session_directory(path)
    if directory is None:
        return None
    manifest = json.loads((directory/'manifest.json').read_text(encoding='utf-8'))
    if manifest.get('container_version') != 2:
        return None
    return manifest


def jsonlines(path, limit=None):
    with Path(path).open('rb') as stream:
        while limit is None or stream.tell() < limit:
            line = stream.readline() if limit is None else stream.readline(limit-stream.tell())
            if not line:
                break
            if not line.endswith(b'\n'):
                raise ValueError('Truncated JSONL metadata')
            yield json.loads(line)


def iter_chunks(path, chunk_size=65536, *, committed=True, start_volume=0, offset=0,
                verify_hash=True, end_absolute=None):
    if chunk_size <= 0:
        raise ValueError('chunk_size must be positive')
    directory = session_directory(path)
    manifest = load_manifest(path) if directory else None
    if manifest is None:
        target = Path(path)
        if target.is_dir():
            target = target/'stream.spif'
        with target.open('rb') as stream:
            stream.seek(offset)
            while chunk := stream.read(chunk_size):
                yield chunk
        return
    volumes = manifest['volumes'] if committed else [dict(name=p.name) for p in sorted(directory.glob('stream-*.spif'))]
    for ordinal, volume in enumerate(volumes):
        if ordinal < start_volume:
            continue
        with (directory/volume['name']).open('rb') as stream:
            skip = offset if ordinal == start_volume else 0
            if end_absolute is not None and volume['start']+skip >= end_absolute:
                return
            stream.seek(skip)
            remaining = volume['bytes']-skip if committed else None
            whole_volume = remaining == volume.get('bytes')
            if end_absolute is not None:
                remaining = min(remaining, end_absolute-volume['start']-skip)
                whole_volume &= remaining == volume['bytes']
            digest = hashlib.sha256()
            while remaining is None or remaining > 0:
                chunk = stream.read(chunk_size if remaining is None else min(chunk_size, remaining))
                if not chunk:
                    if remaining:
                        raise ValueError('Volume shorter than committed boundary')
                    break
                if remaining is not None:
                    remaining -= len(chunk)
                digest.update(chunk)
                yield chunk
            if committed and verify_hash and whole_volume and digest.hexdigest() != volume['sha256']:
                raise ValueError(f'Committed volume SHA256 mismatch: {volume["name"]}')


def iter_records(path, *, frame_min=None, frame_max=None, ticks_min=None, ticks_max=None):
    """Yield packets and extended coordinates; seek via sparse disk index.

    Bounds inclusive. Block min/max bounds include every stream, including delayed
    RESULT and out-of-order packets. Scan only the span of overlapping blocks.
    A range read validates that span, not the entire original experiment.
    """
    for low, high in ((frame_min, frame_max), (ticks_min, ticks_max)):
        if low is not None and low < 0 or high is not None and high < 0:
            raise ValueError('Bounds must be nonnegative')
        if low is not None and high is not None and low > high:
            raise ValueError('Lower bound exceeds upper bound')
    directory = session_directory(path)
    manifest = load_manifest(path) if directory else None
    chosen = end_absolute = None
    if manifest and any(v is not None for v in (frame_min, frame_max, ticks_min, ticks_max)):
        def ranges():
            for entry in jsonlines(directory/'index.jsonl', manifest['index_bytes']):
                if 'range' in entry:
                    yield entry['range']
            if manifest.get('tail_range'):
                yield manifest['tail_range']
        for entry in ranges():
            overlaps = True
            for name, low, high in (('frame', frame_min, frame_max), ('ticks', ticks_min, ticks_max)):
                if low is not None:
                    overlaps &= entry[name+'_max'] is not None and entry[name+'_max'] >= low
                if high is not None:
                    overlaps &= entry[name+'_min'] is not None and entry[name+'_min'] <= high
            if overlaps:
                if chosen is None:
                    chosen = entry
                end_absolute = entry['end_absolute']
        if chosen is None:
            return
    decoder, audit = Decoder(), StreamAudit()
    ordinal = 0
    if chosen:
        audit.frame_high, audit.time_high = chosen['frame_high'], chosen['time_high']
        ordinal = chosen['packet_index']-1
    for chunk in iter_chunks(path, start_volume=chosen['volume'] if chosen else 0,
                             offset=chosen['offset'] if chosen else 0, end_absolute=end_absolute):
        for packet in decoder.feed(chunk):
            ordinal += 1
            frame, ticks = audit.observe(packet)
            selected = not ((frame_min is not None and (frame is None or frame < frame_min))
                or (frame_max is not None and (frame is None or frame > frame_max))
                or (ticks_min is not None and (ticks is None or ticks < ticks_min))
                or (ticks_max is not None and (ticks is None or ticks > ticks_max)))
            if selected:
                yield dict(packet=packet, frame=frame, ticks=ticks, packet_index=ordinal)
    decoder.finish()
    if not audit.summary(decoder)['transport_integrity_ok']:
        raise ValueError('Selected scan contains corruption, sequence gaps or discontinuities')


def verify_session(path, *, recover=False):
    """Read-only scan. Recovery includes uncommitted bytes but certifies no losslessness."""
    directory = session_directory(path)
    manifest = load_manifest(path) if directory else None
    decoder, audit = Decoder(), StreamAudit()
    total = last_complete = 0
    for chunk in iter_chunks(path, committed=not recover, verify_hash=False):
        total += len(chunk)
        for packet in decoder.feed(chunk):
            audit.observe(packet)
            last_complete = decoder.consumed_bytes
    result = dict(**audit.summary(decoder), scanned_bytes=total,
                  last_complete_packet_end=last_complete, trailing_uncertain_bytes=total-last_complete,
                  recovery= recover, original_files_modified=False)
    hashes_ok = True
    if manifest:
        for volume in manifest['volumes']:
            digest = hashlib.sha256()
            with (directory/volume['name']).open('rb') as stream:
                remaining = volume['bytes']
                while remaining:
                    chunk = stream.read(min(65536, remaining))
                    if not chunk:
                        hashes_ok = False
                        break
                    digest.update(chunk)
                    remaining -= len(chunk)
            hashes_ok &= digest.hexdigest() == volume['sha256']
        result.update(committed_hashes_ok=hashes_ok, closed_cleanly=manifest['closed_cleanly'],
                      committed_bytes=manifest['committed_bytes'],
                      uncommitted_bytes=max(0, total-manifest['committed_bytes']))
        result['transport_integrity_ok'] &= hashes_ok and manifest['closed_cleanly'] and not recover
    if recover:
        result['transport_integrity_ok'] = False
        result['recovery_note'] = 'Valid packets are salvageable evidence; missing/unflushed bytes cannot be quantified.'
    return result
