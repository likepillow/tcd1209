import csv
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'host'))
from protocol import INVALID, DISCONTINUITY
from recording import Recorder, replay
from test_protocol import result_packet


class RecordingTests(unittest.TestCase):
    def test_roundtrip_preserves_bytes_invalidity_and_precision(self):
        packets = [result_packet(-2**75-173, seq=0), result_packet(0, flags=INVALID, seq=1)]
        wire = b''.join(p.encode() for p in packets)
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'run'
            callback = []
            with Recorder(target, {'k_units': 'rad/m', 'distance_scale': 1}) as writer:
                for index in range(0, len(wire), 17):
                    writer.append(wire[index:index+17], callback.append)
                writer.flush()
                interim = json.loads((target/'manifest.json').read_text())
                self.assertFalse(interim['closed_cleanly'])
            self.assertEqual((target/'stream.spif').read_bytes(), wire)
            self.assertEqual(list(replay(target/'stream.spif', 1)), packets)
            self.assertEqual(callback, packets)
            status = json.loads((target/'manifest.json').read_text())
            self.assertTrue(status['closed_cleanly'])
            self.assertTrue(status['transport_integrity_ok'])
            self.assertEqual(status['invalid_results'], 1)
            with (target/'distance.csv').open(newline='', encoding='utf-8') as stream:
                records = list(csv.DictReader(stream))
            self.assertEqual(int(records[0]['accumulator']), -2**75-173)
            self.assertEqual(records[1]['distance'], '')
            with self.assertRaises(FileExistsError):
                Recorder(target)
            with self.assertRaises(ValueError):
                writer.append(b'')

    def test_truncation_and_exception_manifest(self):
        with tempfile.TemporaryDirectory() as folder:
            for mode in ('truncated', 'exception'):
                target = Path(folder)/mode
                if mode == 'truncated':
                    with Recorder(target) as writer:
                        writer.append(result_packet(1).encode()[:-1])
                    with self.assertRaises(ValueError):
                        list(replay(target/'stream.spif'))
                else:
                    with self.assertRaises(RuntimeError):
                        with Recorder(target) as writer:
                            writer.append(result_packet(1).encode())
                            raise RuntimeError('USB disconnected')
                status = json.loads((target/'manifest.json').read_text())
                self.assertFalse(status['closed_cleanly'])
                self.assertFalse(status['transport_integrity_ok'])
                self.assertTrue(status['error'])

    def test_corruption_and_gaps_are_saved_but_not_certified(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'run'
            bad = bytearray(result_packet(3, seq=1).encode())
            bad[40] ^= 0x80
            wire = result_packet(2, seq=0).encode()+bad+result_packet(4, seq=2).encode()
            with Recorder(target) as writer:
                writer.append(wire)
            status = json.loads((target/'manifest.json').read_text())
            self.assertTrue(status['closed_cleanly'])
            self.assertFalse(status['transport_integrity_ok'])
            self.assertEqual(status['bad_crc'], 1)
            self.assertEqual(status['missing_packets'], 1)
            self.assertEqual((target/'stream.spif').read_bytes(), wire)
            with self.assertRaises(ValueError):
                list(replay(target/'stream.spif'))

    def test_explicit_device_discontinuity_is_not_hidden(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'run'
            with Recorder(target) as writer:
                writer.append(result_packet(2, flags=DISCONTINUITY).encode())
            status = json.loads((target/'manifest.json').read_text())
            self.assertFalse(status['transport_integrity_ok'])
            self.assertEqual(status['discontinuity_packets'], 1)
            with self.assertRaises(ValueError):
                list(replay(target/'stream.spif'))


if __name__ == '__main__':
    unittest.main()
