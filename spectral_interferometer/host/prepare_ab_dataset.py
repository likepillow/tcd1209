"""Build the A/B NPZ from a JSON manifest, numeric S/K and SPIF captures.

Manifest: source, k, window_start, positions:[{truth, frames}]. Relative paths
resolve beside the manifest. Each position must have unchanged W/T and optical
configuration; the operator supplies the known distance in the signed convention.
"""
import argparse
import json
from pathlib import Path

import numpy as np

from protocol import Decoder, Kind, DISCONTINUITY, SPECTRUM_DTYPE, SequenceTracker
from acquisition_settings import AcquisitionSettings
from reference import crop1024, load_vector
from resampling import uniform_k_grid


def prepare(manifest, output):
    manifest = Path(manifest).resolve()
    spec = json.loads(manifest.read_text(encoding='utf-8-sig'))
    window = int(spec.get('window_start', 512))
    settings = AcquisitionSettings(window, int(spec.get('period_pixels', 2114)))
    source = crop1024(load_vector(manifest.parent/spec['source']), 'S', window)
    k = load_vector(manifest.parent/spec['k'])
    _, k = uniform_k_grid(k, window)
    frames, truth, flags, provenance = [], [], [], []
    for position in spec['positions']:
        path = manifest.parent/position['frames']
        decoder = Decoder()
        sequence = SequenceTracker()
        seen = {}
        sidecar = path.with_name('manifest.json')
        events = []
        if path.name == 'stream.spif' and sidecar.exists():
            status = json.loads(sidecar.read_text(encoding='utf-8-sig'))
            if not status.get('transport_integrity_ok', False):
                raise ValueError(f'Recording manifest does not certify clean transport: {sidecar}')
            events = status.get('metadata', {}).get('acquisition_events', [])
            for event in events:
                if (int(event['window_start']), int(event['period_pixels'])) != (window, settings.period_pixels):
                    raise ValueError(f'W/T differs from source calibration in {sidecar}')
        known_truth = float(position['truth'])
        if not np.isfinite(known_truth):
            raise ValueError('Known position must be finite')
        with path.open('rb') as stream:
            while chunk := stream.read(65536):
                for packet in decoder.feed(chunk):
                    sequence.observe(packet.sequence)
                    if packet.flags & DISCONTINUITY:
                        raise ValueError(f'Device discontinuity in {path}')
                    if packet.kind == Kind.RAW:
                        raw = np.frombuffer(packet.payload, '<u2').copy()
                    elif packet.kind == Kind.SPECTRUM:
                        raw = np.frombuffer(packet.payload, SPECTRUM_DTYPE)['s0'].copy()
                    else:
                        continue
                    if packet.frame_id in seen:
                        slot = seen[packet.frame_id]
                        if not np.array_equal(frames[slot], raw):
                            raise ValueError(f'Conflicting S0 data for frame {packet.frame_id} in {path}')
                        flags[slot] |= packet.flags
                        continue
                    seen[packet.frame_id] = len(frames)
                    frames.append(raw)
                    truth.append(known_truth)
                    flags.append(packet.flags)
        decoder.finish()
        if (decoder.bad_crc or decoder.bad_headers or decoder.bad_payloads or decoder.discarded_bytes
                or sequence.missing or sequence.out_of_order):
            raise ValueError(f'Corrupt SPIF capture: {path}')
        if not seen:
            raise ValueError(f'No S0 frames in {path}; enable S0 export while recording')
        provenance.append({'path': str(path.resolve()), 'frames': len(seen),
                           'wt_confirmed_by_recording': bool(events)})
    with Path(output).open('xb') as stream:
        np.savez_compressed(stream, frames=frames, source=source, k=k, truth=truth, flags=flags,
                            window_start=window, period_pixels=settings.period_pixels,
                            provenance=json.dumps(provenance),
                            input_manifest=manifest.read_text(encoding='utf-8-sig'))
    return len(frames)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(f'Prepared {prepare(args.manifest, args.output)} S0 frames: {args.output}')


if __name__ == '__main__':
    main()
