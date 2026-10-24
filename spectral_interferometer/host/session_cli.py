"""Bounded-memory verify/recover/extract/recompute for SPIF v1/v2 sessions."""
import argparse
import hashlib
import json
from pathlib import Path

from protocol import Kind, SPECTRUM_DTYPE
from session_recording import (SessionWriter, atomic_json, iter_records, jsonlines,
                               load_manifest, session_directory, verify_session)


def source_identity(source):
    directory = session_directory(source)
    path = directory/'manifest.json' if directory else Path(source)
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(65536):
            digest.update(chunk)
    return dict(path=str(Path(source).resolve()), evidence_sha256=digest.hexdigest(),
                hash_scope='manifest (contains volume prefix hashes)' if directory else 'wire bytes')


def extract(source, destination, **bounds):
    """Preserve selected packet bytes, original IDs, and preceding state events.

    A clip is explicitly derived, not an original lossless acquisition. Interleaved
    packets outside the requested bounds can leave sequence holes in the clip.
    """
    writer = SessionWriter(destination, dict(source_mode='derived_clip', source=source_identity(source),
                                            selection=bounds, original_acquisition=False))
    directory = session_directory(source)
    manifest = load_manifest(source) if directory else None
    events = iter(jsonlines(directory/'events.jsonl', manifest['event_bytes'])) if manifest else iter(())
    pending = next(events, None)
    count = 0
    try:
        for record in iter_records(source, **bounds):
            while pending is not None and pending['after_packet'] < record['packet_index']:
                event = dict(pending, source_after_packet=pending['after_packet'],
                             after_packet=count)
                writer.event(event)
                pending = next(events, None)
            writer.append(record['packet'].encode())
            count += 1
        writer.close(extra=dict(derived_clip=True, selected_packets=count))
    except BaseException as error:
        writer.close(str(error))
        raise
    return dict(selected_packets=count, destination=str(destination), derived_clip=True)


def recompute(source, destination, calibration_path, **bounds):
    import numpy as np
    from reference import Calibration, solve
    calibration = Calibration.load(calibration_path)
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    algorithm_file = Path(__file__).with_name('reference.py')
    report = dict(algorithm_id='legacy_spectral_slope_1024',
                  algorithm_sha256=hashlib.sha256(algorithm_file.read_bytes()).hexdigest(),
                  calibration_sha256=hashlib.sha256(Path(calibration_path).read_bytes()).hexdigest(),
                  source=source_identity(source), selection=bounds, complete=False,
                  rows=0, invalid=0, scope='Existing floating-point reference, not D4 paper reproduction')
    # Preserve the exact user-selected calibration; never infer or switch it silently.
    (destination/'calibration.npz').write_bytes(Path(calibration_path).read_bytes())
    try:
        with (destination/'recomputed.jsonl').open('x', encoding='utf-8') as stream:
            for record in iter_records(source, **bounds):
                packet = record['packet']
                if packet.kind not in (Kind.RAW, Kind.SPECTRUM):
                    continue
                values = (np.frombuffer(packet.payload, '<u2') if packet.kind == Kind.RAW else
                          np.frombuffer(packet.payload, SPECTRUM_DTYPE)['s0'])
                row = dict(frame=record['frame'], ticks=record['ticks'], kind=int(packet.kind),
                           packet_index=record['packet_index'], invalid_reason=None)
                try:
                    if np.any((values == 0) | (values == 4095)):
                        raise ValueError('ADC saturation')
                    result = solve(values, calibration)
                    row.update(distance=result['distance'], residual_rms=result['residual_rms'])
                except ValueError as error:
                    row.update(distance=None, invalid_reason=str(error))
                    report['invalid'] += 1
                stream.write(json.dumps(row, allow_nan=False)+'\n')
                report['rows'] += 1
        report['complete'] = True
    except BaseException as error:
        report['error'] = str(error)
        raise
    finally:
        atomic_json(destination/'report.json', report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for name in ('verify', 'summary', 'recover', 'extract', 'recompute'):
        child = commands.add_parser(name)
        child.add_argument('source', type=Path, help='v2 directory/manifest/volume, or legacy .spif')
        if name == 'recover':
            child.add_argument('--report', type=Path, required=True, help='New report file; source is unchanged')
        if name in ('extract', 'recompute'):
            child.add_argument('destination', type=Path)
            for bound in ('frame-min', 'frame-max', 'ticks-min', 'ticks-max'):
                child.add_argument('--'+bound, type=int)
        if name == 'recompute':
            child.add_argument('--calibration', type=Path, required=True)
            child.add_argument('--algorithm', choices=['legacy_spectral_slope_1024'], required=True)
    args = parser.parse_args()
    if args.command in ('verify', 'summary', 'recover'):
        result = verify_session(args.source, recover=args.command == 'recover')
        if args.command == 'recover':
            with args.report.open('x', encoding='utf-8') as stream:
                json.dump(result, stream, ensure_ascii=False, indent=2)
    else:
        bounds = {key: getattr(args, key) for key in ('frame_min', 'frame_max', 'ticks_min', 'ticks_max')}
        if args.command == 'extract':
            result = extract(args.source, args.destination, **bounds)
        else:
            result = recompute(args.source, args.destination, args.calibration, **bounds)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if args.command == 'verify' and not result['transport_integrity_ok']:
        raise SystemExit(2)


if __name__ == '__main__':
    main()
