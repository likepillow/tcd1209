"""Generate exact large-integer MAC expectations from the host calibration."""
import sys
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'host'))
from reference import Calibration
from fixed import FixedFit

out = Path(sys.argv[1]);out.mkdir(parents=True, exist_ok=True)
rng = np.random.default_rng(99451209)
a = FixedFit.from_calibration(Calibration.create(np.ones(1024), np.linspace(1e7, 1.1e7, 1024)))
b = FixedFit.from_calibration(Calibration.create(np.ones(1024), -np.cumsum(rng.uniform(.5, 1.5, 512)), distance_scale=.5))
c = FixedFit(np.zeros(512, dtype=np.int64), -11)
phases = rng.integers(-2**40, 2**40, (6, 1024), dtype=np.int64)
phases[2] = phases[1]+2**38
phases[0, 256] = -2**42;phases[0, 767] = 2**42-1
fits = (a, b, b, b, b, c)
def memory(name, values, width):
    (out/name).write_text(''.join(f'{int(v)&((1<<width)-1):0{(width+3)//4}x}\n' for v in values))
memory('fit_weights.mem', np.concatenate((a.weights, b.weights, c.weights)), 32)
memory('fit_phases.mem', phases.ravel(), 43)
memory('fit_results.mem', [fit.accumulate(p) for fit, p in zip(fits, phases)], 84)
memory('fit_exponents.mem', [fit.exponent for fit in fits], 16)
assert b.accumulate(phases[1]) == b.accumulate(phases[2])
print('Generated six full frames, two nonzero calibrations and zero-scale calibration')
