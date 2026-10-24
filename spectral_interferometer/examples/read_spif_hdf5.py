"""Read a bounded row block from a scientific HDF5 export using h5py."""
import argparse
import h5py
import numpy as np

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('file')
parser.add_argument('--first', type=int, default=0, help='Zero-based S0 row')
parser.add_argument('--count', type=int, default=100)
args = parser.parse_args()
if args.first < 0 or args.count < 0:
    parser.error('--first and --count must be nonnegative')
with h5py.File(args.file, 'r') as h5:
    print('Integrity verified:', bool(h5.attrs['integrity_ok']))
    selection = slice(args.first, args.first+args.count)
    s0 = h5['spectra/s0'][selection]  # uint16, frame x pixel
    frame_id = h5['spectra/frame_id'][selection]
    segment_id = h5['spectra/segment_id'][selection]
    ticks = h5['spectra/timestamp_ticks'][selection]  # keep uint64; no early float conversion
    print('S0 shape/dtype:', s0.shape, s0.dtype)
    wanted = set(zip(segment_id[:3].tolist(), frame_id[:3].tolist()))
    for first in range(0, h5['results/frame_id'].shape[0], 4096):
        selection = slice(first, first+4096)
        segments = h5['results/segment_id'][selection]
        frames = h5['results/frame_id'][selection]
        distances = h5['results/distance'][selection]
        for segment, frame, distance in zip(segments, frames, distances):
            if (int(segment), int(frame)) in wanted:
                print('segment/frame/RESULT:', int(segment), int(frame), float(distance))
