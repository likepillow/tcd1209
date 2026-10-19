"""Wrap existing actual-XFFT RTL simulation outputs for GUI QA; never optical data."""
import argparse
import csv
from pathlib import Path
import sys
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'host'))
from protocol import Kind, Packet, SPECTRUM_DTYPE, RESULT_TAIL, INVALID


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('simulation', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    spectrum = np.loadtxt(args.simulation/'processor_spectrum.csv', delimiter=',', dtype=np.int64)
    phase = np.loadtxt(args.simulation/'processor_phase.csv', delimiter=',', dtype=np.int64)
    with (args.simulation/'processor_results.csv').open() as stream:
        results = list(csv.reader(stream))
    if spectrum.shape != (4096, 5) or phase.shape != (4096, 4) or len(results) != 4:
        raise ValueError('Expected four complete RTL test frames')
    packets = []
    for f, rr in enumerate(results):
        sr, pr = spectrum[f*1024:(f+1)*1024], phase[f*1024:(f+1)*1024]
        fid = int(rr[0])
        if not (np.all(sr[:, 0] == fid) and np.all(pr[:, 0] == fid)
                and np.array_equal(sr[:, 1], np.arange(1024)) and np.array_equal(pr[:, 1], np.arange(1024))):
            raise ValueError('Simulation frame or index mismatch')
        def packet(kind, payload, flags=0):
            packets.append(Packet(kind, len(packets), fid, payload, source_version=int(rr[7]), k_version=int(rr[8]), flags=flags))
        packet(Kind.RAW, sr[:, 2].astype('<u2').tobytes())
        data = np.zeros(1024, SPECTRUM_DTYPE)
        data['s0'], data['s1'], data['s2'] = sr[:, 2], sr[:, 3], sr[:, 4]
        packet(Kind.SPECTRUM, data.tobytes())
        invalid = INVALID if int(rr[3]) else 0
        packet(Kind.PHASE, pr[:, 2].astype('<i8').tobytes(), invalid)
        acc = int(rr[1], 16)
        if acc >= 2**83:
            acc -= 2**84
        payload = acc.to_bytes(12, 'little', signed=True)+RESULT_TAIL.pack(int(rr[2]), *map(int, rr[4:7]), 0, 0)
        packet(Kind.RESULT, payload, invalid)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output/'rtl_simulation.spif').write_bytes(b''.join(p.encode() for p in packets))
    np.savetxt(args.output/'simulation_K.txt', np.linspace(1e7, 1.1e7, 1024), fmt='%.17g', header='RTL synthetic test calibration ONLY; K=rad/m')
    (args.output/'README.txt').write_text('These are four RTL SIMULATION frames, not physical CCD measurements.\n'
                                       'No hardware timestamp is supplied. Source calibration was constant 1024.\n', encoding='utf-8')
    print(f'Exported {len(packets)} packets from existing RTL CSV files; no distance recomputation')


if __name__ == '__main__':
    main()
