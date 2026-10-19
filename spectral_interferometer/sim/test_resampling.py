from pathlib import Path
import sys
import tempfile
import unittest
import json

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'host'))
from resampling import (linear_resample, natural_cubic_resample, linear_map_q20,
                        solve_resampled, subbin_peak)
from ab_evaluate import evaluate
from prepare_ab_dataset import prepare
from protocol import Kind, Packet, SPECTRUM_DTYPE, INVALID


class ResamplingTests(unittest.TestCase):
    def fixture(self, slope=None):
        x = np.linspace(0, 1, 1024)
        k = 7+x+.12*x*x
        source = 2000+100*np.cos(2*x)
        slope = slope if slope is not None else 2*np.pi*64/(k[-1]-k[0])
        frame = source*(1+.35*np.cos(.4+slope*(k-k[0])))
        return frame, source, k, slope

    def test_linear_and_cubic_preserve_linear_function_both_directions(self):
        _, _, k, _ = self.fixture()
        target = np.linspace(k[0], k[-1], 1024)
        values = 3*k-2
        for function in (linear_resample, natural_cubic_resample):
            np.testing.assert_allclose(function(values, k, target), 3*target-2,
                                       rtol=2e-12, atol=2e-12)
            np.testing.assert_allclose(function(values[::-1], k[::-1], target[::-1]),
                                       (3*target-2)[::-1], rtol=2e-12, atol=2e-12)

    def test_resampled_phase_and_map(self):
        frame, source, k, expected = self.fixture()
        for method in ('linear', 'cubic'):
            result = solve_resampled(frame, source, k, method=method)
            self.assertLess(abs(result['slope']/expected-1), 1e-5)
            self.assertEqual(result['peak_bin'], 64)
        base, fraction = linear_map_q20(k)
        self.assertEqual((len(base), len(fraction)), (1024, 1024))
        self.assertTrue(np.all(base <= 1022))
        self.assertTrue(np.all(fraction <= 1 << 20))

    def test_subbin_peak_and_ab_outputs(self):
        x = np.arange(16, dtype=float)
        power = 100-(x-5.25)**2
        self.assertAlmostEqual(subbin_peak(power, 5), .25, places=12)
        frames, truths = [], []
        source = k = None
        for slope in (300., 300., 330., 330.):
            frame, source, k, _ = self.fixture(slope)
            frames.append(frame); truths.append(slope)
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            dataset = root/'dataset.npz'
            np.savez(dataset, frames=frames, source=source, k=k, truth=truths)
            summary = evaluate(dataset, root/'result')
            self.assertIn('decision', summary)
            self.assertFalse(summary['decision']['implement_resampling'])
            for name in ('per_frame.csv', 'summary.json', 'report.md'):
                self.assertTrue((root/'result'/name).is_file())

    def test_descending_coarse_sign_matches_fine_and_bad_frames_rejected(self):
        frame, source, k, expected = self.fixture()
        result = solve_resampled(frame[::-1], source[::-1], k[::-1])
        self.assertLess(result['distance'], 0)
        self.assertLess(result['coarse_parabolic'], 0)
        self.assertLess(abs(result['slope']/(-expected)-1), 1e-5)
        with self.assertRaises(ValueError):
            solve_resampled(source, source, k)
        with self.assertRaises(ValueError):
            solve_resampled(frame, source, k, method='typo')

    def test_invalid_frames_are_counted_instead_of_aborting_report(self):
        frame, source, k, expected = self.fixture()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            np.savez(root/'data.npz', frames=[source, frame, frame], source=source,
                     k=k, truth=[expected, expected, expected])
            summary = evaluate(root/'data.npz', root/'out')
            self.assertEqual(summary['linear']['valid_frames'], 2)
            self.assertAlmostEqual(summary['linear']['invalid_rate'], 1/3)
            self.assertFalse(summary['decision']['implement_resampling'])


    def test_prepare_real_spif_dataset_deduplicates_and_preserves_truth(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            np.savetxt(root/'s.txt', np.full(1024, 2000.))
            np.savetxt(root/'k.txt', np.linspace(7, 8, 1024))
            packet = Packet(Kind.RAW, 0, 10, np.full(1024, 2100, '<u2').tobytes())
            spectrum = np.zeros(1024, SPECTRUM_DTYPE)
            spectrum['s0'] = 2100
            duplicate = Packet(Kind.SPECTRUM, 1, 10, spectrum.tobytes(), flags=INVALID)
            (root/'capture.spif').write_bytes(packet.encode()+duplicate.encode())
            (root/'manifest.json').write_text(json.dumps({'source': 's.txt', 'k': 'k.txt',
                'positions': [{'truth': 123., 'frames': 'capture.spif'}]}), encoding='utf-8')
            self.assertEqual(prepare(root/'manifest.json', root/'data.npz'), 1)
            with np.load(root/'data.npz') as data:
                self.assertEqual(data['frames'].shape, (1, 1024))
                self.assertEqual(data['truth'][0], 123.)
                self.assertTrue(data['flags'][0] & INVALID)
            report = evaluate(root/'data.npz', root/'report')
            self.assertEqual(report['linear']['invalid_rate'], 1.)
            self.assertIsNone(report['linear']['p95_abs_error'])

    def test_prepare_rejects_recorded_wt_mismatch(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            np.savetxt(root/'s.txt', np.full(1024, 2000.))
            np.savetxt(root/'k.txt', np.linspace(7, 8, 1024))
            capture = root/'position'
            capture.mkdir()
            (capture/'stream.spif').write_bytes(Packet(Kind.RAW, 0, 1, bytes(2048)).encode())
            (capture/'manifest.json').write_text(json.dumps({'transport_integrity_ok': True,
                'metadata': {'acquisition_events': [{'window_start': 500, 'period_pixels': 2114}]}}))
            (root/'input.json').write_text(json.dumps({'source': 's.txt', 'k': 'k.txt',
                'positions': [{'truth': 1., 'frames': 'position/stream.spif'}]}))
            with self.assertRaisesRegex(ValueError, 'W/T differs'):
                prepare(root/'input.json', root/'data.npz')
            self.assertFalse((root/'data.npz').exists())

    def test_prepare_rejects_sequence_gap(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            np.savetxt(root/'s.txt', np.full(1024, 2000.))
            np.savetxt(root/'k.txt', np.linspace(7, 8, 1024))
            (root/'capture.spif').write_bytes(Packet(Kind.RAW, 0, 1, bytes(2048)).encode()+
                                             Packet(Kind.RAW, 2, 2, bytes(2048)).encode())
            (root/'input.json').write_text(json.dumps({'source': 's.txt', 'k': 'k.txt',
                'positions': [{'truth': 1., 'frames': 'capture.spif'}]}))
            with self.assertRaisesRegex(ValueError, 'Corrupt SPIF'):
                prepare(root/'input.json', root/'data.npz')


if __name__ == '__main__':
    unittest.main()
