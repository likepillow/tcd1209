"""Uniform-K resampling and coarse/fine software A/B reference algorithms.

This module is deliberately floating point and is not the deployed FPGA path.
Linear interpolation is the candidate RTL architecture; natural cubic is an
offline accuracy reference that requires no SciPy dependency.
"""
import numpy as np

from reference import crop1024, main_lobe, vector


def uniform_k_grid(k, window_start=512):
    from acquisition_settings import AcquisitionSettings
    AcquisitionSettings(window_start=window_start)
    values = vector(k, (1024, 2048), 'K')
    delta = np.diff(values)
    if not (np.all(delta > 0) or np.all(delta < 0)):
        raise ValueError('K must be strictly monotonic')
    if values.size == 2048:
        values = values[window_start:window_start+1024]
    return np.linspace(values[0], values[-1], values.size), values


def linear_resample(values, k, target):
    values = vector(values, (1024,), 'values')
    k = vector(k, (1024,), 'K')
    target = vector(target, (1024,), 'target K')
    if k[-1] < k[0]:
        return np.interp(target[::-1], k[::-1], values[::-1])[::-1]
    return np.interp(target, k, values)


def natural_cubic_resample(values, k, target):
    """Natural cubic spline reference, using a tridiagonal solve."""
    y = vector(values, (1024,), 'values')
    x = vector(k, (1024,), 'K')
    q = vector(target, (1024,), 'target K')
    reverse = x[-1] < x[0]
    if reverse:
        x, y, q = x[::-1], y[::-1], q[::-1]
    h = np.diff(x)
    if np.any(h <= 0):
        raise ValueError('K must be strictly monotonic')
    n = x.size
    lower = h[:-1].copy()
    diagonal = 2*(h[:-1]+h[1:])
    upper = h[1:].copy()
    rhs = 6*((y[2:]-y[1:-1])/h[1:]-(y[1:-1]-y[:-2])/h[:-1])
    # Thomas algorithm for the n-2 interior second derivatives.
    for i in range(1, n-2):
        factor = lower[i]/diagonal[i-1]
        diagonal[i] -= factor*upper[i-1]
        rhs[i] -= factor*rhs[i-1]
    second = np.zeros(n)
    second[-2] = rhs[-1]/diagonal[-1]
    for i in range(n-4, -1, -1):
        second[i+1] = (rhs[i]-upper[i]*second[i+2])/diagonal[i]
    index = np.clip(np.searchsorted(x, q, side='right')-1, 0, n-2)
    hi = index+1
    width = x[hi]-x[index]
    a = (x[hi]-q)/width
    b = (q-x[index])/width
    result = (a*y[index]+b*y[hi] +
              ((a**3-a)*second[index]+(b**3-b)*second[hi])*(width**2)/6)
    return result[::-1] if reverse else result


def subbin_peak(power, peak, mode='parabolic'):
    if peak <= 0 or peak >= len(power)-1:
        return 0.0
    samples = np.asarray(power[peak-1:peak+2], dtype=np.float64)
    if mode == 'log':
        samples = np.log(np.maximum(samples, np.finfo(float).tiny))
    elif mode != 'parabolic':
        raise ValueError('peak mode must be parabolic or log')
    denominator = samples[0]-2*samples[1]+samples[2]
    if not np.isfinite(denominator) or denominator >= 0 or denominator == 0:
        return 0.0
    return float(np.clip(.5*(samples[0]-samples[2])/denominator, -.5, .5))


def solve_resampled(frame, source, k, *, method='linear', distance_scale=1.0,
                    window_start=512, search_lo=1, search_hi=511):
    """Normalize in pixel space, resample S1, then recompute the S2 mean."""
    if method not in ('linear', 'cubic') or not np.isfinite(distance_scale):
        raise ValueError('method must be linear/cubic and distance scale finite')
    s0 = crop1024(frame, 'frame', window_start)
    source = crop1024(source, 'S', window_start)
    if np.any(source <= 0) or np.any(s0 < 0) or np.any(s0 > 4095):
        raise ValueError('invalid source or ADC frame')
    target, pixel_k = uniform_k_grid(k, window_start)
    s1_pixel = s0/source
    interpolate = linear_resample if method == 'linear' else natural_cubic_resample
    s1 = interpolate(s1_pixel, pixel_k, target)
    s2 = s1-s1.mean()
    if np.max(np.abs(s2)) <= 1e-12*max(1.0, float(np.max(np.abs(s1)))):
        raise ValueError('frame contains no resolvable fringe modulation')
    h0 = np.fft.fft(s2)
    power = np.abs(h0)**2
    peak, left, right = main_lobe(power, search_lo, search_hi)
    h1 = np.zeros(1024, dtype=np.complex128)
    h1[left:right+1] = h0[left:right+1]
    s3 = np.fft.ifft(h1)
    amplitude = np.abs(s3)
    if np.min(amplitude) <= np.max(amplitude)*1e-10:
        raise ValueError('analytic amplitude approaches zero; phase is undefined')
    phase = np.unwrap(np.angle(s3))
    fit_k, fit_phase = target[256:768], phase[256:768]
    centered = fit_k-fit_k.mean()
    slope = float(centered@(fit_phase-fit_phase.mean())/(centered@centered))
    delta_parabolic = subbin_peak(power, peak, 'parabolic')
    delta_log = subbin_peak(power, peak, 'log')
    # Signed spacing matches the existing positive-FFT-lobe phase convention.
    dk = (target[-1]-target[0])/1023
    coarse = lambda delta: distance_scale*2*np.pi*(peak+delta)/(1024*dk)
    return dict(S0=s0, S1_pixel=s1_pixel, S1=s1, S2=s2, H0=h0, H1=h1,
                S3=s3, P1=phase, k_uniform=target, peak_bin=peak,
                band_left=left, band_right=right, slope=slope,
                distance=slope*distance_scale,
                coarse_integer=coarse(0), coarse_parabolic=coarse(delta_parabolic),
                coarse_log=coarse(delta_log), delta_parabolic=delta_parabolic,
                delta_log=delta_log)


def linear_map_q20(k, window_start=512):
    """Return base indices and Q0.20 fractions for a future RTL map upload."""
    target, values = uniform_k_grid(k, window_start)
    key, query = (values, target) if values[-1] > values[0] else (-values, -target)
    base = np.clip(np.searchsorted(key, query, side='right')-1, 0, 1022)
    fraction = (target-values[base])/(values[base+1]-values[base])
    q20 = np.clip(np.rint(fraction*(1 << 20)), 0, 1 << 20).astype(np.uint32)
    return base.astype(np.uint16), q20
