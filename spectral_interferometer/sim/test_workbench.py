from dataclasses import replace
import json
from pathlib import Path
import sys
import tempfile
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'host'))
from workbench import DisplayState, LocalCalibration, trend
from receiver import FileReceiver
from protocol import Kind, Packet, Decoder, DISCONTINUITY, SPECTRUM_DTYPE
from acquisition_settings import AcquisitionSettings
from test_protocol import result_packet


class WorkbenchTests(unittest.TestCase):
    def test_optical_clipping_warning_clears_after_valid_raw(self):
        state = DisplayState()
        state.ingest(Packet(Kind.RAW, 0, 1, np.full(1024, 4095, '<u2').tobytes()))
        self.assertIn('1024', state.snapshot()['optical_warning'])
        state.ingest(Packet(Kind.RAW, 1, 2, np.full(1024, 2000, '<u2').tobytes()))
        self.assertEqual(state.snapshot()['optical_warning'], '')

    def test_reference_smoothing_is_reversible_and_not_repeated(self):
        cal = LocalCalibration()
        source = 1000 + 100*np.cos(np.arange(1024)*.5)
        cal.set_source(source, 'measured')
        cal.set_k(np.linspace(7, 8, 1024))
        cal.smooth_source(31)
        filtered = cal.source.copy()
        cal.smooth_source(31)
        np.testing.assert_array_equal(cal.source, filtered)
        self.assertLess(np.std(filtered), np.std(source)*.2)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'smoothed.npz'
            cal.save(path)
            restored = LocalCalibration.load(path)
            restored.restore_source()
            np.testing.assert_array_equal(restored.source, source)
            self.assertEqual(restored.source_origin, 'measured')
        cal.restore_source()
        np.testing.assert_array_equal(cal.source, source)
        for width in (2, 4, 129):
            with self.assertRaises(ValueError):
                cal.smooth_source(width)
        np.testing.assert_array_equal(cal.source, source)

    def test_multiframe_source_average_rejects_bad_and_deduplicates(self):
        state = DisplayState()
        state.begin_source_average(4)
        expected = []
        sequence = 0
        for frame_id, level in enumerate((1000, 1010, 1020, 1030), 20):
            raw = np.full(1024, level, '<u2')
            expected.append(level)
            state.ingest(Packet(Kind.RAW, sequence, frame_id, raw.tobytes()))
            sequence += 1
            # A SPECTRUM packet for the same frame must not be counted twice.
            data = np.zeros(1024, SPECTRUM_DTYPE)
            data['s0'] = raw
            state.ingest(Packet(Kind.SPECTRUM, sequence, frame_id, data.tobytes()))
            sequence += 1
            if frame_id == 20:
                saturated = np.full(1024, 4095, '<u2')
                state.ingest(Packet(Kind.RAW, sequence, 99, saturated.tobytes()))
                sequence += 1
        result = state.take_source_average()
        self.assertEqual(result['count'], 4)
        self.assertEqual(result['rejected'], 1)
        np.testing.assert_allclose(result['source'], np.mean(expected))
        np.testing.assert_allclose(result['std'], np.std(expected, ddof=1))
        self.assertIsNone(state.snapshot()['source_average'])

    def test_source_average_bounds_and_acquisition_change_cancel(self):
        state = DisplayState()
        for count in (1, 4097):
            with self.assertRaises(ValueError):
                state.begin_source_average(count)
        state.begin_source_average(2)
        state.set_acquisition(AcquisitionSettings(100, 2500))
        self.assertIsNone(state.snapshot()['source_average'])

    def test_latest_raw_is_not_replaced_by_older_processed_frame(self):
        state = DisplayState()
        state.ingest(Packet(Kind.RAW, 0, 11, np.full(1024, 1234, '<u2').tobytes()))
        data = np.zeros(1024, SPECTRUM_DTYPE)
        data['s0'] = 987
        data['s1'] = 4096
        data['s2'] = -2048
        state.ingest(Packet(Kind.SPECTRUM, 1, 10, data.tobytes()))
        snap = state.snapshot()
        self.assertEqual(snap['frames'], {'S0': 11, 'S1': 10, 'S2': 10})
        self.assertTrue(np.all(snap['channels']['S0'] == 1234))
        self.assertTrue(np.all(snap['channels']['S1'] == 1))
        self.assertTrue(np.all(snap['channels']['S2'] == -.5))
        with self.assertRaises(ValueError):
            snap['channels']['S0'][0] = 0
        state.ingest(Packet(Kind.RAW, 1, 10, bytes(2048)))
        self.assertEqual(state.snapshot()['out_of_order'], 1)
        self.assertTrue(np.all(state.snapshot()['channels']['S0'] == 1234))

    def test_time_axis_invalids_and_gaps_between_results(self):
        state = DisplayState()
        state.ingest(result_packet(2**70, seq=0))
        state.ingest(Packet(Kind.RAW, 2, 201, bytes(2048)))  # missing sequence=1
        state.ingest(replace(result_packet(2**70+100, seq=3), timestamp=200000))
        x, y, label = trend(state.snapshot()['history'])
        self.assertIn('时间', label)
        self.assertEqual(x[-1], .001)
        self.assertTrue(np.isnan(y[1]))
        state.ingest(replace(result_packet(0, seq=4), timestamp=0, flags=1))
        x, y, label = trend(state.snapshot()['history'])
        self.assertIn('结果序号', label)
        self.assertTrue(np.isnan(y[-1]))
        # A new calibration version must break, not interpolate across units.
        state.ingest(replace(result_packet(1, seq=5), k_version=7))
        self.assertTrue(state.snapshot()['history'][-1][3])

    def test_calibration_full_k_roundtrip_and_commands(self):
        cal = LocalCalibration(scale=.5, k_units='rad/m')
        k = np.linspace(1.1e7, 1e7, 2048)
        cal.set_k(k, 'test K.txt')
        raw = np.arange(2048)+1
        cal.set_source(raw, 'frame 42')
        self.assertEqual(cal.source[0], 513)
        self.assertEqual(cal.source[-1], 1536)
        packets = list(Decoder().feed(cal.commands()))
        self.assertEqual([p.kind for p in packets], [Kind.SOURCE, Kind.K_WEIGHTS])
        for period in (0, 1, 10, 0xffffffff):
            configured = list(Decoder().feed(cal.commands(export_period=period)))
            self.assertEqual([p.kind for p in configured], [Kind.SOURCE, Kind.K_WEIGHTS, Kind.EXPORT])
            self.assertEqual(configured[-1].sequence, 2)
            self.assertEqual(int.from_bytes(configured[-1].payload, 'little'), period)
        with self.assertRaises(ValueError):
            cal.commands(export_period=-1)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'cal.npz'
            cal.save(path)
            loaded = LocalCalibration.load(path)
            np.testing.assert_array_equal(loaded.k, k)
            self.assertEqual(loaded.source_origin, 'frame 42')
            self.assertEqual(loaded.k_units, 'rad/m')
            self.assertEqual(loaded.commands(), cal.commands())
        k[1] = k[0]  # outside final cropped fit region is still rejected
        with self.assertRaises(ValueError):
            cal.set_k(k)
        for bad in (np.zeros(1024), np.full(1024, 4096)):
            with self.assertRaises(ValueError):
                cal.set_source(bad)

    def test_bounded_history_and_no_software_result_for_raw(self):
        state = DisplayState(history_size=3)
        state.ingest(Packet(Kind.RAW, 0, 3, bytes(2048)))
        self.assertEqual(state.snapshot()['result_count'], 0)
        for seq in range(1, 10):
            state.ingest(result_packet(seq, seq=seq))
        self.assertEqual(len(state.snapshot()['history']), 3)
        self.assertEqual(state.snapshot()['result_count'], 9)

    def test_receiver_clean_corrupt_discontinuity_and_copy(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for mode in ('clean', 'crc', 'discontinuity'):
                wire = bytearray(result_packet(17, flags=DISCONTINUITY if mode == 'discontinuity' else 0).encode())
                if mode == 'crc':
                    wire[40] ^= 1
                path = root/(mode+'.spif')
                path.write_bytes(wire)
                state = DisplayState()
                worker = FileReceiver(path, state, result_interval=0, record_to=root/mode)
                worker.start()
                worker.join(5)
                self.assertFalse(worker.is_alive())
                self.assertEqual(worker.failure is None, mode == 'clean')
                self.assertEqual(state.snapshot()['error'], mode != 'clean')
                self.assertEqual((root/mode/'stream.spif').read_bytes(), wire)
                status = json.loads((root/mode/'manifest.json').read_text(encoding='utf-8'))
                self.assertEqual(status['transport_integrity_ok'], mode == 'clean')


if __name__ == '__main__':
    unittest.main()
