"""Check real XFFT/IFFT and RTL phase chain against analytic phase."""
import sys
import numpy as np

data = np.loadtxt(sys.argv[1], delimiter=',', dtype=np.int64)
assert data.shape == (4096, 6), data.shape
for frame, frequency in enumerate((43, 97, 0, 211)):
    rows = data[frame*1024:(frame+1)*1024]
    n = np.arange(1024)
    assert np.all(rows[:, 0] == frame) and np.array_equal(rows[:, 1], n)
    assert np.all(rows[:, 3] == (frame == 2))
    assert np.all(rows[:, 4:] == frequency)
    if frame == 2:
        assert np.all(rows[:, 2] == 0)
    else:
        phase = rows[:, 2]*np.pi/2**31
        error = np.max(np.abs(phase-(.7+2*np.pi*frequency*n/1024)))
        assert error < 1e-5, (frame, error)
        print(f'Frame {frame}: unwrapped phase max error={error:.9g} rad')
print('PASS: FFT/complex band/IFFT/CORDIC/unwrap including empty-frame recovery')
