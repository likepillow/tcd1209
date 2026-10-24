"""Exercise GUI callbacks with mocked dialogs, without native UI automation."""
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'host'))
from viewer import Viewer, Plot
from workbench import DisplayState, LocalCalibration
from protocol import Kind, Packet, Decoder
from reference import Calibration


class ViewerActionTests(unittest.TestCase):
    def test_discrete_plot_ticks_are_integers(self):
        plot = Plot.__new__(Plot)
        plot.canvas = Mock()
        plot.canvas.winfo_width.return_value = 1180
        plot.canvas.winfo_height.return_value = 245
        plot.title, plot.color = 'test', '#123456'
        plot.data = (np.arange(512, 1536), np.sin(np.arange(1024)), 'pixel', 'ADC', True)
        plot.redraw()
        ticks = [call.kwargs['text'] for call in plot.canvas.create_text.call_args_list
                 if len(call.args) > 1 and call.args[1] == 209]
        self.assertEqual(ticks, ['512', '768', '1024', '1279', '1535'])

    def app(self):
        app = Viewer.__new__(Viewer)
        app.root = None
        app.worker = None
        app.window_start = Mock()
        app.exposure_us = Mock()
        app.clock_profile = Mock()
        app.clock_profile.get.return_value = '5 MHz旧版'
        app.result_stride = Mock()
        app.result_stride.get.return_value = '1'
        app.applied_acquisition = None
        app.acquisition_pending = False
        app.display = DisplayState()
        app.calibration = LocalCalibration()
        app.calibration_labels = Mock()
        app.error = Mock()
        app.scale = Mock()
        app.scale.get.return_value = '.5'
        app.units = Mock()
        app.units.get.return_value = 'rad/m'
        app.export_period = Mock()
        app.export_period.get.return_value = '100'
        return app

    def test_current_source_button_copies_one_complete_frame_and_saves_without_k(self):
        app = self.app()
        app.display.ingest(Packet(Kind.RAW, 0, 17, np.full(1024, 1700, '<u2').tobytes()))
        app.capture_source()
        app.display.ingest(Packet(Kind.RAW, 1, 18, np.full(1024, 1800, '<u2').tobytes()))
        self.assertTrue(np.all(app.calibration.source == 1700))
        self.assertIn('17', app.calibration.source_origin)
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'source.txt'
            with patch('viewer.filedialog.asksaveasfilename', return_value=str(path)):
                app.save_source()
            self.assertTrue(np.all(np.loadtxt(path) == 1700))
        app.error.assert_not_called()
        self.assertIsNone(app.calibration.k)

    def test_load_k_export_config_and_save_load_calibration(self):
        app = self.app()
        app.calibration.set_source(np.full(1024, 2048), 'source')
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            path = root/'k.txt'
            np.savetxt(path, np.linspace(1.1e7, 1e7, 2048))
            with patch('viewer.filedialog.askopenfilename', return_value=str(path)):
                app.load_k()
            self.assertEqual(len(app.calibration.k), 2048)
            with patch('viewer.filedialog.asksaveasfilename', return_value=str(root/'commands.spif')):
                app.export_commands()
            commands = list(Decoder().feed((root/'commands.spif').read_bytes()))
            self.assertEqual([p.kind for p in commands], [Kind.SOURCE, Kind.K_WEIGHTS, Kind.EXPORT])
            self.assertEqual(int.from_bytes(commands[2].payload, 'little'), 100)
            with patch('viewer.filedialog.asksaveasfilename', return_value=str(root/'cal.npz')):
                app.save_calibration()
            app.calibration = LocalCalibration()
            with patch('viewer.filedialog.askopenfilename', return_value=str(root/'cal.npz')):
                app.load_calibration()
            self.assertEqual(app.calibration.scale, .5)
            self.assertEqual(app.calibration.k_units, 'rad/m')
        app.error.assert_not_called()

    def test_missing_source_reports_error_and_bad_k_does_not_replace_good(self):
        app = self.app()
        app.capture_source()
        self.assertEqual(app.error.call_count, 1)
        app.calibration.set_k(np.arange(2048))
        with tempfile.TemporaryDirectory() as folder:
            bad = np.arange(2048, dtype=float)
            bad[0] = bad[1]
            path = Path(folder)/'bad.txt'
            np.savetxt(path, bad)
            with patch('viewer.filedialog.askopenfilename', return_value=str(path)):
                app.load_k()
            self.assertEqual(app.error.call_count, 2)
            np.testing.assert_array_equal(app.calibration.k, np.arange(2048))
            with self.assertRaises(ValueError):
                Calibration.create(np.ones(1024), bad)


if __name__ == '__main__':
    unittest.main()
