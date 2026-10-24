"""Bounded-memory SPIF -> HDF5 + CSV. Original SPIF is never modified.

HDF5 is a scientific exchange file, NOT a MATLAB MAT v7.3 file. MATLAB h5read
may present axes in reversed order; use the supplied reader to obtain frame x pixel.
"""
import argparse
from contextlib import nullcontext
import csv
import hashlib
import json
from pathlib import Path
import sys
import time

import numpy as np
from session_recording import iter_chunks, jsonlines, load_manifest, session_directory

from protocol import (Decoder, DistanceResult, Kind, SequenceTracker, TIME_VALID,
                      DISCONTINUITY, SPECTRUM_DTYPE)


def _h5py():
    try:
        import h5py
    except ModuleNotFoundError:
        # Project-local optional dependencies, installed without modifying Python.
        sys.path.append(str(Path(__file__).resolve().parents[1]/'.cache/research_export_deps'))
        import h5py
    return h5py


class IntegrityError(ValueError):
    pass


class Rows:
    def __init__(self, group, columns, batch=256):
        self.group, self.columns, self.batch = group, columns, batch
        self.buffer, self.count = [], 0
        for key, (dtype, tail) in columns.items():
            ds = group.create_dataset(key, shape=(0,)+tail, maxshape=(None,)+tail,
                dtype=dtype, chunks=(batch,)+tail, compression='gzip', compression_opts=1,
                shuffle=True, fletcher32=True)
            ds.attrs['axis_order'] = 'frame,pixel' if tail == (1024,) else 'row'

    def append(self, row):
        self.buffer.append(row)
        if len(self.buffer) >= self.batch:
            self.flush()

    def flush(self):
        if not self.buffer:
            return
        end = self.count+len(self.buffer)
        for key, (dtype, tail) in self.columns.items():
            ds = self.group[key]
            ds.resize((end,)+tail)
            ds[self.count:end] = np.asarray([r[key] for r in self.buffer], dtype=dtype)
        self.count = end
        self.buffer.clear()


COMMON = {key: (dtype, ()) for key, dtype in (
    ('sequence', '<u4'), ('frame_id', '<u4'), ('timestamp_ticks', '<u8'),
    ('flags', '<u2'), ('source_version', '<u4'), ('k_version', '<u4'),
    ('packet_index', '<u8'), ('segment_id', '<u4'), ('window_start', '<i4'),
    ('period_pixels', '<u8'), ('pixel_ticks', '<u2'), ('packet_kind', 'u1'),
    ('time_seconds', '<f8'))}


def export_recording(source, destination, *, spectra_csv=False, frame_min=None,
                     frame_max=None, allow_damaged=False, progress=None, cancel=None):
    """Exclusive output folder. Failed exports retain .partial.h5 and report.json.

    Frame limits are inclusive, independently within each segment. Unknown W/T
    is encoded as window_start=-1, period_pixels=0, pixel_ticks=0, never invented.
    Manifest and acknowledged calibration events are preserved verbatim.
    """
    source, destination = Path(source), Path(destination)
    session_dir = session_directory(source)
    session_manifest = load_manifest(source) if session_dir else None
    if not source.is_file() and session_manifest is None:
        raise FileNotFoundError(source)
    if frame_min is not None and not 0 <= frame_min <= 0xffffffff:
        raise ValueError('Invalid minimum frame ID')
    if frame_max is not None and not 0 <= frame_max <= 0xffffffff:
        raise ValueError('Invalid maximum frame ID')
    if frame_min is not None and frame_max is not None and frame_min > frame_max:
        raise ValueError('Minimum frame ID exceeds maximum')
    h5py = _h5py()
    manifest_path = session_dir/'manifest.json' if session_manifest else source.with_name('manifest.json')
    manifest = session_manifest or (json.loads(manifest_path.read_text(encoding='utf-8')) if manifest_path.exists() else {})
    metadata = manifest.get('metadata', {})
    events = {}
    v2_events = iter(jsonlines(session_dir/'events.jsonl', manifest['event_bytes'])) if session_manifest else iter(())
    next_v2_event = next(v2_events, None)
    for event in metadata.get('acquisition_events', []):
        events.setdefault(int(event['after_packet']), []).append(('acquisition', event))
    for event in metadata.get('run_events', []):
        events.setdefault(int(event['after_packet']), []).append(('run', event))
    destination.mkdir(parents=True, exist_ok=False)
    partial = destination/'research.partial.h5'
    report = dict(schema='SPIF-research-1', source=str(source.resolve()),
                  exporter_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  complete=False, integrity_ok=False, selected_frame_min=frame_min,
                  selected_frame_max=frame_max, allow_damaged=allow_damaged,
                  spectra_rows=0, result_rows=0, processed_rows=0, phase_rows=0)
    decoder, tracker, digest = Decoder(), SequenceTracker(), hashlib.sha256()
    settings, segment, previous = None, 0, {}
    stable_path = manifest_path if session_manifest else source
    source_stat = stable_path.stat()
    bytes_read, total_bytes = 0, manifest['committed_bytes'] if session_manifest else source_stat.st_size
    origin_ticks = {}
    boundary_events = []
    last_progress = 0.0
    discontinuity_packets = 0
    max_device_dropped = max_device_malformed = selected_invalid_results = selected_raw_rail_frames = 0

    def apply_events(index):
        nonlocal settings, segment, previous, next_v2_event
        current = list(events.get(index, ()))
        while next_v2_event is not None and next_v2_event['after_packet'] <= index:
            event = next_v2_event
            current.append((event['type'], event))
            group = calibration.create_group('v2_'+str(event['event_id']))
            group.create_dataset('acknowledged_event_json', data=json.dumps(event, ensure_ascii=False),
                                 dtype=h5py.string_dtype('utf-8'))
            for key in ('source', 'k', 'dark_field'):
                details = event.get('calibration') or {}
                if key in details:
                    group.create_dataset(key, data=np.asarray(details[key], dtype='<f8'))
            next_v2_event = next(v2_events, None)
        for kind, event in current:
            if kind == 'acquisition':
                settings = event
            if kind == 'acquisition' or event.get('running', False):
                segment += 1
                previous = {}
            boundary_events.append(dict(packet_index=index, kind=kind, segment_id=segment))

    try:
        with h5py.File(partial, 'x') as h5, (destination/'distance.csv').open('x', newline='', encoding='utf-8') as df:
            h5.attrs.update(schema='SPIF-research-1', complete=False, integrity_ok=False,
                timestamp_clock_hz=100_000_000, timestamp_unit='10 ns ticks, not wall time',
                matrix_axis_order='frame,pixel (HDF5 file order)',
                missing_configuration='window_start=-1;period_pixels=0;pixel_ticks=0',
                distance_units='Defined by acknowledged K and distance_scale; unknown if absent',
                source_path=str(source.resolve()))
            raw_rows = Rows(h5.create_group('spectra'), {**COMMON, 's0': ('<u2', (1024,))})
            raw_rows.group.create_dataset('pixel_offset', data=np.arange(1024, dtype='<u2'))
            raw_rows.group['s0'].attrs['unit'] = '12-bit ADC counts; no smoothing or resampling'
            result_columns = {**COMMON, 'distance': ('<f8', ()), 'invalid': ('u1', ()),
                'accumulator_bytes': ('u1', (12,)), 'exponent': ('<i2', ()),
                **{x: ('<u4', ()) for x in ('peak', 'left', 'right', 'dropped_frames', 'malformed_frames')}}
            result_rows = Rows(h5.create_group('results'), result_columns)
            processed_rows = Rows(h5.create_group('processed'), {**COMMON,
                's1_fixed': ('<u4', (1024,)), 's2_fixed': ('<i4', (1024,))})
            phase_rows = Rows(h5.create_group('phase'), {**COMMON, 'phase_fixed': ('<i8', (1024,))})
            processed_rows.group['s1_fixed'].attrs['divide_by'] = 4096
            processed_rows.group['s2_fixed'].attrs['divide_by'] = 4096
            phase_rows.group['phase_fixed'].attrs['radian_scale'] = np.pi/2**31
            calibration = h5.create_group('calibration')
            for index, event in enumerate(metadata.get('configuration_events', [])):
                group = calibration.create_group(str(index))
                group.create_dataset('acknowledged_event_json', data=json.dumps(event, ensure_ascii=False),
                                     dtype=h5py.string_dtype('utf-8'))
                details = event.get('calibration') or {}
                for key in ('source', 'k'):
                    if key in details:
                        group.create_dataset(key, data=np.asarray(details[key], dtype='<f8'))
                payload = bytes.fromhex(event.get('payload_hex', ''))
                if payload:
                    group.create_dataset('command_payload', data=np.frombuffer(payload, 'u1'))
            # JSON contains exact uint64/int values without lossy float conversion.
            h5.create_dataset('manifest_json', data=json.dumps(manifest, ensure_ascii=False),
                              dtype=h5py.string_dtype('utf-8'))
            csv_keys = [k for k in result_columns if k != 'accumulator_bytes']
            distance_writer = csv.writer(df)
            distance_writer.writerow(csv_keys+['accumulator_decimal'])
            sf = (destination/'spectra.csv').open('x', newline='', encoding='utf-8') if spectra_csv else None
            spectrum_writer = csv.writer(sf) if sf else None
            if spectrum_writer:
                spectrum_writer.writerow(list(COMMON)+[f'pixel_offset_{i}' for i in range(1024)])
            try:
                apply_events(0)
                with nullcontext(iter_chunks(source, verify_hash=not allow_damaged)) as blocks:
                    for block in blocks:
                        if cancel is not None and cancel.is_set():
                            raise InterruptedError('Export cancelled; original SPIF unchanged')
                        bytes_read += len(block)
                        digest.update(block)
                        for packet in decoder.feed(block):
                            tracker.observe(packet.sequence)
                            if packet.kind in (Kind.RAW, Kind.SPECTRUM, Kind.RESULT, Kind.PHASE):
                                decoded_result = DistanceResult.from_packet(packet) if packet.kind == Kind.RESULT else None
                                if decoded_result is not None:
                                    max_device_dropped = max(max_device_dropped, decoded_result.dropped_frames)
                                    max_device_malformed = max(max_device_malformed, decoded_result.malformed_frames)
                                key = Kind.RAW if packet.kind == Kind.SPECTRUM else packet.kind
                                last = previous.get(key)
                                # Compare within each channel: RAW and RESULT may interleave at different latencies.
                                reset = bool(last and ((packet.flags & TIME_VALID and last[2] and packet.timestamp < last[1])
                                    or ((packet.frame_id-last[0]) & 0xffffffff) >= 2**31))
                                if reset:
                                    segment += 1
                                    previous = {}
                                    boundary_events.append(dict(packet_index=decoder.packets,
                                        kind='inferred_counter_reset', segment_id=segment))
                                if packet.flags & DISCONTINUITY:
                                    # RAW decimation also raises this bit. It is not a reset epoch.
                                    discontinuity_packets += 1
                                    boundary_events.append(dict(packet_index=decoder.packets,
                                        kind='flagged_discontinuity', segment_id=segment))
                                previous[key] = (packet.frame_id, packet.timestamp, bool(packet.flags & TIME_VALID))
                                if packet.flags & TIME_VALID:
                                    origin_ticks.setdefault(segment, packet.timestamp)
                                selected = ((frame_min is None or packet.frame_id >= frame_min) and
                                            (frame_max is None or packet.frame_id <= frame_max))
                                if selected:
                                    row = {k: getattr(packet, k) for k in ('sequence', 'frame_id', 'timestamp',
                                        'flags', 'source_version', 'k_version')}
                                    row['timestamp_ticks'] = row.pop('timestamp')
                                    row.update(packet_index=decoder.packets, segment_id=segment,
                                        window_start=int(settings['window_start']) if settings else -1,
                                        period_pixels=int(settings['period_pixels']) if settings else 0,
                                        pixel_ticks=int(settings.get('pixel_ticks', 20)) if settings else 0,
                                        packet_kind=int(packet.kind), time_seconds=(packet.timestamp-origin_ticks[segment])/1e8
                                            if packet.flags & TIME_VALID else float('nan'))
                                    if packet.kind in (Kind.RAW, Kind.SPECTRUM):
                                        values = (np.frombuffer(packet.payload, '<u2') if packet.kind == Kind.RAW else
                                                  np.frombuffer(packet.payload, SPECTRUM_DTYPE)['s0'])
                                        raw_rows.append(dict(row, s0=values.copy()))
                                        selected_raw_rail_frames += int(np.any((values == 0)|(values == 4095)))
                                        if spectrum_writer:
                                            spectrum_writer.writerow([row[k] for k in COMMON]+values.tolist())
                                        if packet.kind == Kind.SPECTRUM:
                                            a = np.frombuffer(packet.payload, SPECTRUM_DTYPE)
                                            processed_rows.append(dict(row, s1_fixed=a['s1'].copy(), s2_fixed=a['s2'].copy()))
                                    elif packet.kind == Kind.PHASE:
                                        phase_rows.append(dict(row, phase_fixed=np.frombuffer(packet.payload, '<i8').copy()))
                                    else:
                                        result = decoded_result
                                        selected_invalid_results += int(result.invalid)
                                        out = dict(row, distance=result.distance, invalid=int(result.invalid),
                                            accumulator_bytes=np.frombuffer(packet.payload[:12], 'u1').copy(),
                                            **{k: getattr(result, k) for k in ('exponent', 'peak', 'left', 'right',
                                                'dropped_frames', 'malformed_frames')})
                                        result_rows.append(out)
                                        distance_writer.writerow([out[k] for k in csv_keys]+[str(result.accumulator)])
                            apply_events(decoder.packets)
                        if progress and time.monotonic()-last_progress >= .1:
                            progress(bytes_read, total_bytes)
                            last_progress = time.monotonic()
                trailing_error = None
                final_stat = stable_path.stat()
                if (final_stat.st_size, final_stat.st_mtime_ns) != (source_stat.st_size, source_stat.st_mtime_ns):
                    raise IntegrityError('Input changed during export; stop recording before exporting this file')
                try:
                    decoder.finish()
                except ValueError as error:
                    trailing_error = str(error)
                for rows in (raw_rows, result_rows, processed_rows, phase_rows):
                    rows.flush()
                report.update(source_sha256=digest.hexdigest(), source_bytes=bytes_read,
                    packets=decoder.packets, spectra_rows=raw_rows.count, result_rows=result_rows.count,
                    processed_rows=processed_rows.count, phase_rows=phase_rows.count,
                    bad_headers=decoder.bad_headers, bad_crc=decoder.bad_crc,
                    bad_payloads=decoder.bad_payloads, discarded_bytes=decoder.discarded_bytes,
                    missing_packets=tracker.missing, out_of_order_packets=tracker.out_of_order,
                    trailing_error=trailing_error, segments=segment+1,
                    discontinuity_packets=discontinuity_packets,
                    data_continuity_warning=bool(discontinuity_packets or max_device_dropped or max_device_malformed),
                    max_device_dropped_frames=max_device_dropped, max_device_malformed_frames=max_device_malformed,
                    selected_invalid_results=selected_invalid_results, selected_raw_rail_frames=selected_raw_rail_frames,
                    device_counter_scope='Maximum cumulative counters observed across whole source, not a selected-row loss count')
                # Recorder's legacy aggregate also includes intentional RAW decimation.
                # Byte-stream integrity and sampled-data continuity must stay distinct.
                manifest_warning = manifest.get('transport_integrity_ok') is False
                manifest_bad = (manifest.get('closed_cleanly') is False or bool(manifest.get('error')) or
                    any(manifest.get(k, 0) for k in ('bad_headers', 'bad_crc', 'bad_payloads',
                        'discarded_bytes', 'missing_packets', 'out_of_order_packets')) or
                    (manifest_warning and not manifest.get('discontinuity_packets', 0)))
                report['integrity_ok'] = not (trailing_error or manifest_bad or any(report[k] for k in
                    ('bad_headers', 'bad_crc', 'bad_payloads', 'discarded_bytes', 'missing_packets', 'out_of_order_packets')))
                report['manifest_integrity_warning'] = manifest_warning
                h5.attrs['source_sha256'] = report['source_sha256']
                h5.attrs['integrity_ok'] = report['integrity_ok']
                h5.attrs['integrity_scope'] = 'Byte-stream integrity only, NOT all CCD frames or optical validity'
                h5.attrs['data_continuity_warning'] = report['data_continuity_warning']
                h5.create_dataset('boundaries_json', data=json.dumps(boundary_events), dtype=h5py.string_dtype())
                h5.attrs['complete'] = report['integrity_ok'] or allow_damaged
                if not report['integrity_ok'] and not allow_damaged:
                    raise IntegrityError('Recording integrity check failed; see report.json; partial HDF5 retained')
            finally:
                if sf:
                    sf.close()
        partial.rename(destination/'research.h5')
        report['complete'] = True
        return report
    except Exception as error:
        report['error'] = str(error)
        report['source_bytes_read'] = bytes_read
        if 'raw_rows' in locals():
            report.update(spectra_rows=raw_rows.count, result_rows=result_rows.count,
                processed_rows=processed_rows.count, phase_rows=phase_rows.count)
        raise
    finally:
        (destination/'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False), encoding='utf-8')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path, help='New output directory; never overwritten')
    parser.add_argument('--spectra-csv', action='store_true')
    parser.add_argument('--frame-min', type=int)
    parser.add_argument('--frame-max', type=int)
    parser.add_argument('--allow-damaged', action='store_true')
    args = parser.parse_args()
    report = export_recording(args.source, args.destination, spectra_csv=args.spectra_csv,
        frame_min=args.frame_min, frame_max=args.frame_max, allow_damaged=args.allow_damaged)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
