"""Numerical tests for uploaded K weights, before connecting FPGA MAC RTL."""
import sys
import unittest
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'host'))
from reference import Calibration
from fixed import FixedFit


class FitTests(unittest.TestCase):
    def test_units_directions_scales_and_quantization_bound(self):
        rng = np.random.default_rng(9945)
        k_shape = np.cumsum(rng.uniform(.5, 1.5, 512))
        phase = np.rint((.7+np.arange(512)*.81)*2**31/np.pi).astype(np.int64)
        for unit in (1e-10, 1., 1e12):
            for direction in (-1, 1):
                for scale in (0., .5, 1., -1.):
                    with self.subTest(unit=unit, direction=direction, scale=scale):
                        cal = Calibration.create(np.ones(1024), k_shape*unit*direction, distance_scale=scale)
                        fit = FixedFit.from_calibration(cal)
                        self.assertEqual(int(fit.weights.sum()), 0)
                        result = fit.distance(fit.accumulate(phase))
                        p = (phase-phase[0])*np.pi/2**31
                        expected = float(cal.weights@p)*scale
                        actual_weights = np.ldexp(fit.weights.astype(float), -fit.exponent)*2**31/np.pi
                        bound = float(np.abs(actual_weights-cal.weights*scale)@np.abs(p))
                        self.assertLessEqual(abs(result-expected), bound+abs(expected)*1e-13+1e-25)
                        if scale:
                            self.assertLess(abs((result-expected)/expected), 1e-7)
                            self.assertEqual(np.sign(result), np.sign(direction*scale))

    def test_exact_intercept_invariance_and_middle_crop(self):
        cal = Calibration.create(np.ones(1024), np.linspace(1e7, 1.1e7, 1024))
        fit = FixedFit.from_calibration(cal)
        phase = np.arange(1024, dtype=np.int64)*2**29
        baseline = fit.accumulate(phase)
        self.assertEqual(baseline, fit.accumulate(phase+2**38))
        self.assertEqual(baseline, fit.accumulate(phase[256:768]))
        phase[:256] = -2**41
        phase[768:] = 2**41
        self.assertEqual(baseline, fit.accumulate(phase))

    def test_input_range_and_integer_mac(self):
        fit = FixedFit.from_calibration(Calibration.create(np.ones(1024), np.arange(512)))
        phases = np.where(fit.weights < 0, -2**42, 2**42-1).astype(np.int64)
        result = fit.accumulate(phases)
        self.assertGreater(result, 2**63)
        self.assertLess(result, 2**83)
        for bad in (np.zeros(511, dtype=np.int64), np.zeros(512), np.full(512, 2**42, dtype=np.int64)):
            with self.assertRaises(ValueError):
                fit.accumulate(bad)


if __name__ == '__main__':
    unittest.main()
