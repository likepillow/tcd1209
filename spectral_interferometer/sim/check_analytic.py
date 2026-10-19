"""Compare actual XFFT + filter + IFFT output to an analytical complex sinusoid."""
import sys
import numpy as np

data=np.loadtxt(sys.argv[1],delimiter=",",dtype=np.int64)
assert data.shape==(2048,6), data.shape
for frame,freq in enumerate((43,97)):
    block=data[frame*1024:(frame+1)*1024]
    np.testing.assert_array_equal(block[:,0],np.full(1024,frame))
    np.testing.assert_array_equal(block[:,1],np.arange(1024))
    expected=524288*np.exp(1j*(2*np.pi*freq*np.arange(1024)/1024+.7))
    actual=block[:,2]+1j*block[:,3]
    error=float(np.max(np.abs(actual-expected)))
    phase_error=float(np.max(np.abs(np.angle(actual*np.conj(expected)))))
    assert error<32, (frame,error)
    assert phase_error<1e-4, (frame,phase_error)
    np.testing.assert_array_equal(block[:,4:],np.full((1024,2),freq))
    print(f"Frame {frame}: complex max error={error:.6g} LSB, phase max error={phase_error:.6g} rad")
print("PASS: analytic output matches complex sinusoid; weaker tone rejected")
