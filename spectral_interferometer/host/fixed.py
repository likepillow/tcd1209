"""Fixed-point calibration and normalization contract shared with RTL tests."""
from dataclasses import dataclass
import math
import numpy as np
from reference import crop1024


def reciprocal_q30(source):
    source = crop1024(source, "S")
    if np.any(source < 1):
        raise ValueError("S must be at least one ADC count")
    gains = np.floor(2**30 / source + .5).astype(np.int64)
    if np.any(gains == 0) or np.any(gains > 2**30):
        raise ValueError("S cannot be represented by reciprocal Q30")
    return gains


def normalize_q12(frame, gain):
    raw = crop1024(frame, "frame")
    if np.any(raw != np.floor(raw)) or np.any(raw < 0) or np.any(raw > 4095):
        raise ValueError("ADC samples must be unsigned 12-bit integers")
    g = np.asarray(gain, dtype=np.int64)
    if g.shape != (1024,) or np.any(g < 1) or np.any(g > 2**30):
        raise ValueError("gain must be 1024 positive Q30 reciprocals <= 1")
    s1 = (raw.astype(np.int64)*g + 2**17) >> 18
    mean = int(s1.sum()) >> 10
    return s1, s1-mean


@dataclass(frozen=True)
class FixedFit:
    """FPGA result contract: distance = signed_accumulator * 2**(-exponent).

    The uploaded integer weights include binary-phase-to-radian conversion
    and the explicit distance scale. The host only converts output units.
    """
    weights: np.ndarray
    exponent: int

    @classmethod
    def from_calibration(cls, calibration):
        real_weights = calibration.weights * (np.pi/2**31) * calibration.distance_scale
        if not np.all(np.isfinite(real_weights)):
            raise ValueError('Fit coefficients overflow; check K units and distance scale')
        maximum = float(np.max(np.abs(real_weights)))
        if maximum == 0:
            if calibration.distance_scale != 0:
                raise ValueError('Fit coefficients underflow; check K units and distance scale')
            weights = np.zeros(512, dtype=np.int64)
            exponent = 0
        else:
            # Largest magnitude lies in [2^29,2^30); leave correction headroom.
            exponent = 30-math.frexp(maximum)[1]
            scaled = np.ldexp(real_weights, exponent)
            weights = np.rint(scaled).astype(np.int64)
            correction = -int(weights.sum())
            if abs(correction) > 512:
                raise ValueError('Ill-conditioned fit: coefficient sum cannot be balanced')
            # Adjust the coefficients with the largest rounding residual first,
            # minimizing added error while guaranteeing EXACT integer zero sum.
            if correction:
                residual = scaled-weights
                order = np.argsort(-np.sign(correction)*residual, kind='stable')
                weights[order[:abs(correction)]] += int(np.sign(correction))
            if np.any(weights < -2**31) or np.any(weights >= 2**31) or int(weights.sum()) != 0:
                raise ValueError('Fit weights cannot be represented by signed 32-bit values')
        weights.setflags(write=False)
        return cls(weights, exponent)

    def accumulate(self, phase):
        """Exact 84-bit MAC oracle; accepts 1024 unwrapped or 512 fit samples."""
        values = np.asarray(phase)
        if values.shape == (1024,):
            values = values[256:768]
        if values.shape != (512,) or not np.issubdtype(values.dtype, np.integer):
            raise ValueError('Phase must be 512 or 1024 signed binary-phase integers')
        if np.any(values < -2**42) or np.any(values >= 2**42):
            raise ValueError('Phase exceeds signed 43-bit range')
        # Python integers avoid NumPy int64 overflow for the 75-bit products.
        result = sum(int(p)*int(w) for p, w in zip(values, self.weights))
        if not -2**83 <= result < 2**83:
            raise ValueError('Fit accumulator overflow')
        return result

    def distance(self, accumulator):
        return math.ldexp(int(accumulator), -self.exponent)
