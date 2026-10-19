"""End-to-end integer spectrum and independently computed phase/distance oracle."""
import argparse
import csv
import struct
import sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'host'))
from reference import Calibration, main_lobe
from fixed import FixedFit, reciprocal_q30, normalize_q12
from protocol import Packet, Kind, NO_FRAME, Decoder, export_command


def inputs(clipping=False):
    n = np.arange(1024)
    raw = []
    for frequency in (43, 72.35, 0, 97):
        signal = np.full(1024, 2048.) if frequency == 0 else (
            2048+800*np.cos(.7+2*np.pi*frequency*n/1024)+100*np.cos(2*np.pi*173*n/1024))
        raw.append(np.rint(signal).astype(np.int64))
    raw = np.array(raw)
    if clipping:
        # A single clipped pixel must invalidate the entire result. Frame 3
        # then proves recovery without clearing calibration or resetting.
        raw[1, -1] = 4095
    return raw


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--clipping', action='store_true')
    args = parser.parse_args()
    out = args.directory
    cal = Calibration.create(np.full(1024, 1024.), np.linspace(1e7, 1.1e7, 1024))
    fit = FixedFit.from_calibration(cal)
    raw = inputs(args.clipping)
    if not args.check:
        out.mkdir(parents=True, exist_ok=True)
        def memory(name, values, width):
            (out/name).write_text(''.join(f'{int(v)&((1<<width)-1):0{(width+3)//4}x}\n' for v in values))
        memory('processor_raw.mem', raw.ravel(), 12)
        memory('processor_weights.mem', fit.weights, 32)
        memory('processor_exponent.mem', [fit.exponent], 16)
        source_payload = b''.join(int(v).to_bytes(4, 'little') for v in reciprocal_q30(cal.source))
        k_payload = struct.pack('<hH', fit.exponent, 0) + b''.join(
            int(v).to_bytes(4, 'little', signed=True) for v in fit.weights)
        commands = (Packet(Kind.SOURCE, 11, NO_FRAME, source_payload).encode()
                    + Packet(Kind.K_WEIGHTS, 12, NO_FRAME, k_payload).encode()
                    + export_command(2, 13).encode())
        assert len(commands) == 6272
        decoded = list(Decoder().feed(commands))
        assert len(decoded) == 3 and decoded[0].payload == source_payload and decoded[1].payload == k_payload
        memory('processor_config.mem', commands, 8)
        return
    spectrum = np.loadtxt(out/'processor_spectrum.csv', delimiter=',', dtype=np.int64)
    phase = np.loadtxt(out/'processor_phase.csv', delimiter=',', dtype=np.int64)
    with (out/'processor_results.csv').open() as stream:
        results = list(csv.reader(stream))
    assert spectrum.shape == (4096, 5) and phase.shape == (4096, 4) and len(results) == 4
    n = np.arange(1024)
    for f in range(4):
        sr = spectrum[f*1024:(f+1)*1024]
        pr = phase[f*1024:(f+1)*1024]
        rr = results[f]
        assert np.all(sr[:, 0] == 200+f) and np.all(pr[:, 0] == 200+f) and int(rr[0]) == 200+f
        assert np.array_equal(sr[:, 1], n) and np.array_equal(pr[:, 1], n)
        s1, s2 = normalize_q12(raw[f], reciprocal_q30(cal.source))
        assert np.array_equal(sr[:, 2], raw[f]) and np.array_equal(sr[:, 3], s1) and np.array_equal(sr[:, 4], s2)
        accumulator = int(rr[1], 16)
        if accumulator >= 2**83:
            accumulator -= 2**84
        assert accumulator == fit.accumulate(pr[:, 2]), (f, 'RTL MAC differs from exact integer sum')
        invalid = f == 2 or (args.clipping and f == 1)
        assert int(rr[2]) == fit.exponent and int(rr[3]) == invalid
        assert np.all(pr[:, 3] == invalid)
        peak, left, right = map(int, rr[4:7])
        assert int(rr[7]) == 1 and int(rr[8]) == 1
        if f == 2:
            assert accumulator == 0 and peak == left == right == 0
            continue
        assert peak == (43, 72, 0, 97)[f] and 1 <= left <= peak <= right <= 511
        magnitude=int(np.abs(s2).max())
        shift=30-magnitude.bit_length() if magnitude else 0
        h = np.fft.fft(s2.astype(float)*2**shift)
        assert (peak, left, right) == main_lobe(np.abs(h)**2), (f, 'Principal band differs from floating oracle')
        filtered = np.zeros(1024, dtype=complex)
        filtered[left:right+1] = h[left:right+1]
        expected_phase = np.unwrap(np.angle(np.fft.ifft(filtered)))
        hardware_phase = pr[:, 2]*np.pi/2**31
        phase_error = float(np.max(np.abs(hardware_phase-expected_phase)))
        assert phase_error < 2e-4, (f, phase_error)
        expected_distance = float(cal.weights@(expected_phase[256:768]-expected_phase[256]))
        distance = fit.distance(accumulator)
        # A weighted phase-error bound checks the physical-unit conversion.
        bound = float(np.abs(cal.weights).sum())*phase_error + abs(expected_distance)*1e-8
        assert abs(distance-expected_distance) <= bound+1e-15
        print(f'Frame {f}: band={left}..{right}, phase error={phase_error:.9g} rad, '
              f'distance={distance:.12g}, reference={expected_distance:.12g}, delta={distance-expected_distance:.4g}')
    print('PASS: raw pixels -> normalization -> real FFT/IFFT -> phase -> exact FPGA distance; all export streams checked')
    if args.clipping:
        print('PASS: clipped input propagates INVALID through phase and RESULT; next healthy frame recovers')


if __name__ == '__main__':
    main()
