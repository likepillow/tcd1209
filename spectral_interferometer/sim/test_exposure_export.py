"""Extended settings and streaming scientific export, no hardware required."""
import csv
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'host'))
from acquisition_settings import AcquisitionSettings
from protocol import Packet, Decoder, Kind, TIME_VALID, INVALID, DISCONTINUITY, acquisition_command, RESULT_TAIL
from recording import Recorder
from workbench import LocalCalibration
from research_export import export_recording, IntegrityError, _h5py


def raw(seq, frame, ticks, flags=TIME_VALID):
    return Packet(Kind.RAW, seq, frame, np.arange(1024, dtype='<u2').tobytes(), ticks, 1, 2, flags)


def result(seq, frame, ticks, invalid=False):
    payload = (123456789012345678901).to_bytes(12, 'little', signed=True)+RESULT_TAIL.pack(40, 20, 19, 21, 0, 0)
    return Packet(Kind.RESULT, seq, frame, payload, ticks, 1, 2, TIME_VALID|(INVALID if invalid else 0))


class ExposureExportTests(unittest.TestCase):
    def test_decimated_raw_discontinuity_is_not_a_reset_or_result_mismatch(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with Recorder(root/'session') as rec:
                rec.append(raw(0, 100, 1000).encode()+result(1, 100, 1000).encode())
                rec.append(raw(2, 200, 2001000, TIME_VALID|DISCONTINUITY).encode()+result(3, 200, 2001000).encode())
            report = export_recording(root/'session/stream.spif', root/'out')
            self.assertTrue(report['integrity_ok'])
            self.assertTrue(report['manifest_integrity_warning'])
            self.assertTrue(report['data_continuity_warning'])
            with _h5py().File(root/'out/research.h5') as h:
                self.assertEqual(h['spectra/segment_id'][:].tolist(), [0, 0])
                self.assertEqual(h['results/segment_id'][:].tolist(), [0, 0])

    def test_extended_settings_and_large_period_exact_roundtrip(self):
        for text in ('200', '200.08', '10000', '3600000000'):
            s = AcquisitionSettings.from_text(40, text, 8, 4)
            packet = acquisition_command(s, 8)
            decoded = list(Decoder().feed(packet.encode()))[0]
            self.assertEqual(decoded.kind, Kind.EXPOSURE)
            self.assertEqual(AcquisitionSettings.decode(decoded.payload), s)
        self.assertEqual(AcquisitionSettings.from_text(40, '200', 8, 5).result_hz, 1000)
        self.assertLess(AcquisitionSettings.from_text(40, '200', 8, 6).result_hz, 1000)
        maximum = AcquisitionSettings(40, 2**61-1, 8)
        self.assertEqual(AcquisitionSettings.decode(maximum.encode()), maximum)
        for text in ('199.92', '200.01', 'nan', '-1'):
            with self.assertRaises(ValueError):
                AcquisitionSettings.from_text(40, text, 8)
        for p, stride in ((2500, 0), (2**61, 1), (2500, 2**32)):
            with self.assertRaises(ValueError):
                AcquisitionSettings(40, p, 8, stride)

    def test_calibration_profile_is_preserved_and_cannot_be_mismatched(self):
        cal = LocalCalibration(window_start=40, period_pixels=2500, pixel_ticks=8)
        cal.set_source(np.ones(1024)*1000)
        cal.set_k(np.linspace(7, 8, 1024))
        self.assertFalse(cal.matches(AcquisitionSettings(40, 2500)))
        with tempfile.TemporaryDirectory() as folder:
            file = Path(folder)/'cal.npz'
            cal.save(file)
            loaded = LocalCalibration.load(file)
            self.assertTrue(loaded.matches(AcquisitionSettings(40, 2500, 8)))

    def test_hdf5_csv_integer_types_metadata_and_sparse_join(self):
        h5py = _h5py()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            session = root/'session'
            start = 2**54+7
            with Recorder(session) as rec:
                rec.acquisition_applied(AcquisitionSettings(40, 2500, 8, 4))
                rec.append(raw(0, 100, start).encode()+result(1, 100, start).encode())
                rec.append(result(2, 104, start+80000, True).encode())
                rec.append(raw(3, 200, start+2000000).encode())
            report = export_recording(session/'stream.spif', root/'out', spectra_csv=True)
            self.assertTrue(report['integrity_ok'])
            self.assertEqual(report['spectra_rows'], 2)
            with h5py.File(root/'out/research.h5') as h:
                self.assertEqual(h['spectra/s0'].shape, (2, 1024))
                self.assertEqual(h['spectra/s0'].dtype, np.dtype('uint16'))
                self.assertEqual(int(h['spectra/timestamp_ticks'][0]), start)
                self.assertEqual(int(h['spectra/window_start'][0]), 40)
                self.assertEqual(int(h['spectra/pixel_ticks'][0]), 8)
                self.assertTrue(np.isnan(h['results/distance'][1]))
                self.assertEqual(int.from_bytes(h['results/accumulator_bytes'][0].tobytes(), 'little', signed=True), 123456789012345678901)
                self.assertEqual(h['spectra/frame_id'][:].tolist(), [100, 200])
                self.assertEqual(h['results/frame_id'][:].tolist(), [100, 104])
            with (root/'out/distance.csv').open() as f:
                rows = list(csv.DictReader(f))
            self.assertEqual(int(rows[0]['timestamp_ticks']), start)
            self.assertEqual(rows[0]['accumulator_decimal'], '123456789012345678901')
            self.assertEqual(rows[1]['invalid'], '1')

    def test_bad_crc_truncation_and_explicit_recovery(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            good = raw(0, 1, 100).encode()
            broken = bytearray(raw(1, 2, 200).encode()); broken[-1] ^= 1
            file = root/'bad.spif'
            file.write_bytes(good+broken+raw(2, 3, 300).encode()+b'SP')
            with self.assertRaises(IntegrityError):
                export_recording(file, root/'strict')
            report = json.loads((root/'strict/report.json').read_text())
            self.assertFalse(report['complete'])
            self.assertEqual(report['bad_crc'], 1)
            self.assertTrue((root/'strict/research.partial.h5').exists())
            self.assertFalse((root/'strict/research.h5').exists())
            recovered = export_recording(file, root/'recovered', allow_damaged=True)
            self.assertTrue(recovered['complete'])
            self.assertFalse(recovered['integrity_ok'])
            self.assertEqual(recovered['spectra_rows'], 2)
            with self.assertRaises(FileExistsError):
                export_recording(file, root/'recovered', allow_damaged=True)

    def test_frame_range_unknown_configuration_and_cancel(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder);file = root/'stream.spif'
            file.write_bytes(b''.join(raw(i, i, i*20000).encode() for i in range(300)))
            report = export_recording(file, root/'selected', frame_min=4, frame_max=7)
            self.assertEqual(report['spectra_rows'], 4)
            with _h5py().File(root/'selected/research.h5') as h:
                self.assertTrue(np.all(h['spectra/window_start'][:] == -1))
            cancelled = threading.Event();cancelled.set()
            with self.assertRaises(InterruptedError):
                export_recording(file, root/'cancelled', cancel=cancelled)
            self.assertFalse(json.loads((root/'cancelled/report.json').read_text())['complete'])

    def test_multiple_chunks_calibration_and_optional_processed_channels(self):
        from protocol import SPECTRUM_DTYPE, source_command
        h5py = _h5py()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            with Recorder(root/'session') as rec:
                command = source_command(np.full(1024, 1000.), 7)
                ack = Packet(Kind.ACK, 0, 0xffffffff, (7).to_bytes(4, 'little')+bytes(4), source_version=1)
                rec.command_applied(command, ack, dict(source=[1000.]*1024, k=[7., 8.]))
                for i in range(300):
                    rec.append(raw(i, i, 100+i*20000).encode())
                a = np.zeros(1024, SPECTRUM_DTYPE)
                a['s0'] = 500;a['s1'] = 8192;a['s2'] = -123
                rec.append(Packet(Kind.SPECTRUM, 300, 301, a.tobytes(), 9000000, flags=TIME_VALID).encode())
                rec.append(Packet(Kind.PHASE, 301, 301, np.arange(1024, dtype='<i8').tobytes(), 9000000, flags=TIME_VALID).encode())
            report = export_recording(root/'session/stream.spif', root/'out')
            self.assertEqual((report['spectra_rows'], report['processed_rows'], report['phase_rows']), (301, 1, 1))
            with h5py.File(root/'out/research.h5') as h:
                self.assertEqual(h['spectra/s0'].shape, (301, 1024))
                self.assertTrue(np.all(h['processed/s2_fixed'][0] == -123))
                self.assertEqual(h['calibration/0/source'].shape, (1024,))
                self.assertEqual(h['calibration/0/command_payload'].shape, (4096,))
                self.assertEqual(h['phase/phase_fixed'].attrs['radian_scale'], np.pi/2**31)


if __name__ == '__main__':
    unittest.main()
