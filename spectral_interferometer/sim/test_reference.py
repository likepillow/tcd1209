"""Analytical checks independent of an FPGA implementation."""
import sys
import tempfile
import unittest
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "host"))
from reference import Calibration, solve, main_lobe, load_vector


class ReferenceTests(unittest.TestCase):
    def fixture(self, frequency=43, direction=1):
        n = np.arange(2048)
        source = 1500 + 200 * np.cos(n * .003)
        k = 7.0 + direction * n * 1e-4
        phase = 0.7 + 2 * np.pi * frequency * (n - 512) / 1024
        frame = source * (1 + .45 * np.cos(phase))
        return frame, source, k

    def test_exact_tone_and_complex_ifft(self):
        frame, source, k = self.fixture()
        result = solve(frame, Calibration.create(source, k))
        expected = 2 * np.pi * 43 / (1024 * 1e-4)
        self.assertAlmostEqual(result["slope"], expected, places=8)
        self.assertAlmostEqual(result["distance"], expected, places=8)
        np.testing.assert_allclose(result["S0"], frame[512:1536])
        self.assertEqual(result["peak_bin"], 43)
        self.assertEqual(np.count_nonzero(result["H1"]), 1)
        np.testing.assert_allclose(result["S3"], .225 * np.exp(
            1j * (.7 + 2 * np.pi * 43 * np.arange(1024) / 1024)), atol=1e-12)
        self.assertEqual(result["P0"][0], result["P1"][0])
        self.assertLess(result["residual_rms"], 1e-11)

    def test_descending_k_and_explicit_scale(self):
        frame, source, k = self.fixture(direction=-1)
        result = solve(frame, Calibration.create(source, k, distance_scale=.5))
        self.assertLess(result["slope"], 0)
        self.assertEqual(result["distance"], .5 * result["slope"])

    def test_crop_alignment(self):
        frame, source, k = self.fixture()
        full = solve(frame, Calibration.create(source, k))
        small = solve(frame[512:1536], Calibration.create(source[512:1536], k[768:1280]))
        self.assertEqual(full["slope"], small["slope"])

    def test_noninteger_fringe_quantized_adc(self):
        frame, source, k = self.fixture(frequency=43.27)
        result = solve(np.rint(frame), Calibration.create(source, k))
        expected = 2 * np.pi * 43.27 / (1024 * 1e-4)
        self.assertLess(abs(result["slope"] / expected - 1), 2e-3)
        self.assertEqual(result["peak_bin"], 43)

    def test_valley_boundaries_and_other_peak(self):
        power = np.zeros(1024)
        power[8:15] = [1, 3, 10, 7, 2, 4, 6]
        self.assertEqual(main_lobe(power), (10, 8, 12))

    def test_invalid_calibration_and_frames(self):
        frame, source, k = self.fixture()
        for bad in (np.zeros(1024), np.full(1024, np.nan)):
            with self.assertRaises(ValueError):
                Calibration.create(bad, k)
        for bad in (np.ones(512), np.r_[np.arange(511), 1], np.full(512, np.inf)):
            with self.assertRaises(ValueError):
                Calibration.create(source, bad)
        cal = Calibration.create(source, k)
        for bad in (source, np.full(1024, 4096), np.full(1024, np.nan), np.ones(1000)):
            with self.assertRaises(ValueError):
                solve(bad, cal)

    def test_persistence_and_txt(self):
        frame, source, k = self.fixture()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "calibration.npz"
            cal = Calibration.create(source, k, distance_scale=.5)
            cal.save(path)
            restored = Calibration.load(path)
            self.assertEqual(solve(frame, cal)["distance"], solve(frame, restored)["distance"])
            text_path = Path(directory) / "k.txt"
            np.savetxt(text_path, k)
            np.testing.assert_array_equal(load_vector(text_path), k)


if __name__ == "__main__":
    unittest.main(verbosity=2)
