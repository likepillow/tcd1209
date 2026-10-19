"""Floating-point oracle for the requested 1024/512 spectral algorithm.

No resampling or window is silently inserted. K is in user-specified units;
distance defaults to the phase/K slope, exactly as requested.
"""
from dataclasses import dataclass
from pathlib import Path
import argparse
import json

import numpy as np


def vector(value, lengths, name):
    a = np.asarray(value, dtype=np.float64)
    if a.ndim != 1 or a.size not in lengths or not np.all(np.isfinite(a)):
        raise ValueError(f"{name}: expected a finite 1-D vector of length {lengths}")
    return a.copy()


def crop1024(value, name, window_start=512):
    from acquisition_settings import AcquisitionSettings
    AcquisitionSettings(window_start=window_start)
    a = vector(value, (1024, 2048), name)
    return a[window_start:window_start+1024].copy() if a.size == 2048 else a


def load_vector(path):
    """One value per line; whitespace, blank lines and # comments supported."""
    return np.loadtxt(Path(path), dtype=np.float64, ndmin=1)


@dataclass(frozen=True)
class Calibration:
    source: np.ndarray
    k_fit: np.ndarray
    weights: np.ndarray
    distance_scale: float
    source_floor: float
    k_direction: int
    window_start: int = 512

    @classmethod
    def create(cls, source, k, *, distance_scale=1.0, source_floor=1.0, window_start=512):
        s = crop1024(source, "S", window_start)
        ka = vector(k, (512, 1024, 2048), "K")
        # Check the full supplied K before cropping, not only the fit interval.
        delta = np.diff(ka)
        if not (np.all(delta > 0) or np.all(delta < 0)):
            raise ValueError("K must be strictly monotonic")
        direction = 1 if delta[0] > 0 else -1
        if ka.size == 2048:
            ka = ka[window_start:window_start+1024]
        if ka.size == 1024:
            ka = ka[256:768]
        if not np.isfinite(source_floor) or source_floor <= 0:
            raise ValueError("source_floor must be positive and finite")
        if np.any(s < source_floor):
            raise ValueError("S contains pixels below source_floor; recapture reference")
        if not np.isfinite(distance_scale):
            raise ValueError("distance_scale must be finite")
        # Subtract an anchor before averaging to preserve small K differences.
        centered = ka - ka[0]
        centered -= centered.mean()
        denominator = float(centered @ centered)
        if denominator <= 0 or not np.isfinite(denominator):
            raise ValueError("K has no numerically resolvable fit span")
        weights = centered / denominator
        for arr in (s, ka, weights):
            arr.setflags(write=False)
        return cls(s, ka, weights, float(distance_scale), float(source_floor), direction, window_start)

    def save(self, path):
        np.savez_compressed(path, source=self.source, k_fit=self.k_fit,
                            distance_scale=self.distance_scale, source_floor=self.source_floor,
                            window_start=self.window_start)

    @classmethod
    def load(cls, path):
        with np.load(path, allow_pickle=False) as data:
            return cls.create(data["source"], data["k_fit"],
                              distance_scale=float(data["distance_scale"]),
                              source_floor=float(data["source_floor"]),
                              window_start=int(data['window_start']) if 'window_start' in data else 512)


def main_lobe(power, lo=1, hi=511):
    """Positive-frequency maximum, then walk down each side to first valley.

    Returns inclusive bounds. Equal-height plateaus are included. Tiny floating
    roundoff at an isolated sinusoid's zero bins must not extend the whole band.
    Search limits exclude DC and Nyquist for N=1024.
    """
    if not (1 <= lo <= hi <= 511):
        raise ValueError("positive-frequency search range must lie in 1..511")
    p = int(lo + np.argmax(power[lo:hi + 1]))
    if not np.isfinite(power[p]) or power[p] <= np.finfo(float).tiny:
        raise ValueError("no nonzero positive-frequency peak")
    epsilon = power[p] * 1e-24
    left = right = p
    while left > lo and power[left - 1] <= power[left] and power[left - 1] > epsilon:
        left -= 1
    while right < hi and power[right + 1] <= power[right] and power[right + 1] > epsilon:
        right += 1
    return p, left, right


def solve(frame, calibration, *, search_lo=1, search_hi=511):
    s0 = crop1024(frame, "frame", calibration.window_start)
    if np.any(s0 < 0) or np.any(s0 > 4095):
        raise ValueError("frame must contain unsigned 12-bit ADC samples")
    s1 = s0 / calibration.source
    s2 = s1 - s1.mean()
    if np.max(np.abs(s2)) <= 1e-12 * max(1.0, float(np.max(np.abs(s1)))):
        raise ValueError("frame contains no resolvable fringe modulation")
    h0 = np.fft.fft(s2)
    power = h0.real ** 2 + h0.imag ** 2
    peak, left, right = main_lobe(power, search_lo, search_hi)
    h1 = np.zeros(1024, dtype=np.complex128)
    h1[left:right + 1] = h0[left:right + 1]
    s3 = np.fft.ifft(h1)
    amplitude = np.abs(s3)
    if np.min(amplitude) <= np.max(amplitude) * 1e-10:
        raise ValueError("analytic amplitude approaches zero; phase is undefined")
    p0 = np.angle(s3)
    p1 = np.unwrap(p0)  # First output phase equals the first wrapped phase.
    fit_phase = p1[256:768]
    slope = float(calibration.weights @ (fit_phase - fit_phase[0]))
    intercept = float(fit_phase.mean() - slope * calibration.k_fit.mean())
    residual = fit_phase - fit_phase.mean() - slope * (
        calibration.k_fit - calibration.k_fit.mean())
    return dict(S0=s0, S1=s1, S2=s2, H0=h0, H1=h1, S3=s3, P0=p0, P1=p1,
                slope=slope, distance=slope * calibration.distance_scale,
                intercept=intercept, residual_rms=float(np.sqrt(np.mean(residual ** 2))),
                peak_bin=peak, band_left=left, band_right=right,
                saturated_pixels=int(np.count_nonzero((s0 == 0) | (s0 == 4095))),
                k_direction=calibration.k_direction)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("frame", help="1024 cropped or 2048 effective ADC pixels, txt")
    parser.add_argument("source", help="source reference in matching ADC units, txt")
    parser.add_argument("k", help="512 fit, 1024 cropped, or 2048 effective K values, txt")
    parser.add_argument("--distance-scale", type=float, default=1.0)
    parser.add_argument("--output", type=Path, required=True, help="all stages as NPZ")
    args = parser.parse_args()
    cal = Calibration.create(load_vector(args.source), load_vector(args.k),
                             distance_scale=args.distance_scale)
    result = solve(load_vector(args.frame), cal)
    np.savez_compressed(args.output, **result)
    print(json.dumps({key: value for key, value in result.items()
                      if not isinstance(value, np.ndarray)}, indent=2))


if __name__ == "__main__":
    main()
