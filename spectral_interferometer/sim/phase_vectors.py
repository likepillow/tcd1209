"""Independent atan2/unwrap oracle for full-range CORDIC simulation."""
import argparse
from pathlib import Path
import numpy as np


def vectors():
    rng = np.random.default_rng(1209945)
    n = np.arange(1024)
    frames = []
    for frequency in (43, -211):
        phase = .7 + 2*np.pi*frequency*n/1024
        frames.append(np.column_stack((np.rint(2**30*np.cos(phase)),
                                       np.rint(2**30*np.sin(phase)))).astype(np.int64))
    frames.append(rng.integers(-2**42, 2**42, (1024, 2), dtype=np.int64))
    frames.append(rng.integers(-16, 17, (1024, 2), dtype=np.int64))
    corners = np.array([(0, 0), (1, 0), (-1, 0), (0, 1), (0, -1),
                        (1, 1), (-1, 1), (-1, -1), (1, -1),
                        (-2**42, -2**42), (2**42-1, 2**42-1),
                        (-2**42, 1), (-2**42, -1), (1, -2**42),
                        (2**42-1, 1), (2**42-1, -1)], dtype=np.int64)
    frames.append(np.tile(corners, (64, 1)))
    frames.append(rng.integers(-2**20, 2**20, (1024, 2), dtype=np.int64))
    return np.concatenate(frames)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('directory', type=Path)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    raw = vectors()
    if not args.check:
        args.directory.mkdir(parents=True, exist_ok=True)
        for c, name in enumerate(('phase_re.mem', 'phase_im.mem')):
            (args.directory/name).write_text(''.join(f'{int(x)&((1<<43)-1):011x}\n' for x in raw[:, c]))
        return
    p = np.loadtxt(args.directory/'cordic_output.csv', delimiter=',', dtype=np.int64)
    u = np.loadtxt(args.directory/'unwrap_output.csv', delimiter=',', dtype=np.int64)
    assert p.shape == (6144, 4) and u.shape == (6144, 4), (p.shape, u.shape)
    index = np.arange(6144) % 1024
    assert np.array_equal(p[:, 0], index) and np.array_equal(u[:, 0], index)
    assert np.array_equal(p[:, 2], index == 1023) and np.array_equal(u[:, 2], index == 1023)
    zeros = np.all(raw == 0, axis=1)
    assert np.array_equal(p[:, 3], zeros)
    phase = p[:, 1]*np.pi/2**31
    expected = np.arctan2(raw[:, 1], raw[:, 0])
    error = np.angle(np.exp(1j*(phase-expected)))
    max_error = np.max(np.abs(error[~zeros]))
    assert max_error < 1e-7, max_error
    # Integer unwrap is evaluated from the observed, separately validated
    # wrapped phase. This separates CORDIC error from unwrap arithmetic.
    for f in range(6):
        sl = slice(f*1024, (f+1)*1024)
        wrapped = p[sl, 1]
        deltas = np.diff(wrapped)
        ambiguous = np.abs(deltas) == 2**31
        deltas = np.where(deltas > 2**31, deltas-2**32,
                          np.where(deltas < -2**31, deltas+2**32, deltas))
        unwrapped = np.r_[wrapped[0], wrapped[0]+np.cumsum(deltas)]
        invalid = np.logical_or.accumulate(zeros[sl] | np.r_[False, ambiguous])
        assert np.array_equal(u[sl, 1], unwrapped), f
        assert np.array_equal(u[sl, 3], invalid), f
        if f < 2:
            ideal = np.unwrap(expected[sl])
            assert np.max(np.abs(u[sl, 1]*np.pi/2**31-ideal)) < 1e-7
    print(f'CORDIC max circular phase error: {max_error:.9g} rad')
    print('PASS: 6144 atan2 values; six complete unwrap frames, extrema, tiny vectors, zero/ambiguity flags')


if __name__ == '__main__':
    main()
