import sys
from pathlib import Path
import unittest
import tempfile
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from acquisition_settings import AcquisitionSettings
from protocol import acquisition_command, Decoder, Kind
from workbench import LocalCalibration
from workbench import DisplayState
from recording import Recorder
from receiver import FileReceiver
from protocol import Packet


class AcquisitionSettingsTests(unittest.TestCase):
    def test_defaults_and_endpoints(self):
        for w in (0, 512, 1024):
            for t in ('422.8', '500', '999.8'):
                settings = AcquisitionSettings.from_text(w, t)
                self.assertGreater(settings.nominal_hz, 1000)
                self.assertEqual(AcquisitionSettings.decode(settings.encode()), settings)
        self.assertEqual(AcquisitionSettings().period_pixels, 2114)

    def test_reject_unsafe_or_unrepresentable_values(self):
        for w, t in [(-1, 500), (1025, 500), ('0.5', 500),
                     (512, '422.6'), (512, 1000), (512, '500.1'),
                     ('nan', 500), (512, 'inf'), (512, 'abc')]:
            with self.subTest(w=w, t=t), self.assertRaises(ValueError):
                AcquisitionSettings.from_text(w, t)

    def test_wire_round_trip(self):
        settings = AcquisitionSettings.from_text(1024, '999.8')
        packet = acquisition_command(settings, 42)
        decoder = Decoder()
        received = []
        for byte in packet.encode():
            received.extend(decoder.feed(bytes([byte])))
        decoder.finish()
        self.assertEqual(received, [packet])
        self.assertEqual(received[0].kind, Kind.ACQUISITION)
        self.assertEqual(AcquisitionSettings.decode(received[0].payload), settings)

    def test_calibration_crops_and_persists_settings(self):
        for w in (0, 400, 1024):
            calibration = LocalCalibration(window_start=w, period_pixels=2500)
            calibration.set_source(np.arange(2048)+1)
            calibration.set_k(np.arange(2048)**2)
            built = calibration.build()
            np.testing.assert_array_equal(built.source, np.arange(w, w+1024)+1)
            np.testing.assert_array_equal(built.k_fit, np.arange(w+256, w+768)**2)
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory)/'calibration.npz'
                calibration.save(path)
                loaded = LocalCalibration.load(path)
                self.assertEqual((loaded.window_start, loaded.period_pixels), (w, 2500))
                np.testing.assert_array_equal(loaded.build().weights, built.weights)

    def test_recorded_window_boundary_replays(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'capture'
            settings = AcquisitionSettings(400, 2500)
            with Recorder(path) as recorder:
                recorder.append(Packet(Kind.ACK, 0, 0xffffffff, bytes(8)).encode())
                recorder.acquisition_applied(settings)
                recorder.append(Packet(Kind.RAW, 1, 20, np.arange(1024, dtype='<u2').tobytes()).encode())
            display = DisplayState()
            worker = FileReceiver(path/'stream.spif', display, result_interval=0)
            worker.run()
            self.assertIsNone(worker.failure)
            self.assertEqual(display.snapshot()['acquisition'], settings)
            self.assertEqual(display.snapshot()['frames']['S0'], 20)


if __name__ == '__main__':
    unittest.main()
