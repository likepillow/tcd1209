"""D1 critical paths: evidence boundaries, bounded queues, recovery and seeking."""
import hashlib
import json
from pathlib import Path
import struct
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'host'))
from protocol import Decoder, Kind, Packet, TIME_VALID
from recording import replay
from session_recording import (AsyncSessionRecorder, SessionWriter, iter_records,
                               jsonlines, verify_session)
from session_cli import extract
import session_recording
from live_receiver import USBReceiver
from receiver import FileReceiver
from workbench import DisplayState
from test_run_control import FakeUSB


def raw(seq, frame=None, ticks=None):
    return Packet(Kind.RAW, seq & 0xffffffff, (seq if frame is None else frame) & 0xffffffff,
                  bytes(2048), seq*100000 if ticks is None else ticks, flags=TIME_VALID)


class SessionRecordingTests(unittest.TestCase):
    def test_half_packets_rotation_seek_and_replay(self):
        packets = [raw(i) for i in range(20)]
        wire = b''.join(p.encode() for p in packets)
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'session'
            writer = SessionWriter(target, volume_bytes=3000, index_interval=3)
            for i in range(0, len(wire), 777):
                writer.append(wire[i:i+777])
            writer.close()
            manifest = json.loads((target/'manifest.json').read_text())
            self.assertTrue(manifest['closed_cleanly'])
            self.assertEqual(len(manifest['volumes']), 10)
            self.assertEqual(b''.join((target/v['name']).read_bytes() for v in manifest['volumes']), wire)
            for volume in manifest['volumes']:
                data = (target/volume['name']).read_bytes()
                decoder = Decoder()
                self.assertEqual(len(list(decoder.feed(data))), 2)
                decoder.finish()
                self.assertEqual(volume['sha256'], hashlib.sha256(data).hexdigest())
            self.assertEqual(list(replay(target)), packets)
            self.assertEqual([r['packet'] for r in iter_records(target, frame_min=7, frame_max=12)], packets[7:13])
            self.assertEqual([r['packet'] for r in iter_records(target, ticks_min=700000, ticks_max=1200000)], packets[7:13])
            self.assertTrue(verify_session(target)['transport_integrity_ok'])

    def test_corruption_preserved_recovery_never_relabels_original(self):
        bad = bytearray(raw(1).encode()); bad[-1] ^= 1
        wire = raw(0).encode()+bad+raw(2).encode()+raw(3).encode()[:17]
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'session'
            writer = SessionWriter(target, volume_bytes=1000)
            writer.append(wire)
            writer.close()
            before = {p.name: p.read_bytes() for p in target.iterdir()}
            report = verify_session(target, recover=True)
            self.assertEqual(report['bad_crc'], 1)
            self.assertEqual(report['missing_packets'], 1)
            self.assertEqual(report['trailing_uncertain_bytes'], 17)
            self.assertFalse(report['transport_integrity_ok'])
            self.assertEqual(before, {p.name:p.read_bytes() for p in target.iterdir()})
            self.assertEqual(b''.join(p.read_bytes() for p in sorted(target.glob('*.spif'))), wire)

    def test_crash_tail_after_checkpoint(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'session'
            writer = SessionWriter(target)
            writer.append(raw(0).encode()); writer.checkpoint()
            writer.append(raw(1).encode()+raw(2).encode()[:40])
            writer._close_files()  # Crash simulation: no manifest commit/clean close.
            report = verify_session(target, recover=True)
            self.assertEqual(report['packets'], 2)
            self.assertEqual(report['uncommitted_bytes'], len(raw(1).encode())+40)
            self.assertFalse(report['closed_cleanly'])
            self.assertEqual(len(list(iter_records(target))), 1)

    def test_wrap_independent_stream_gaps_and_duplicates(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'session'
            writer = SessionWriter(target, index_interval=1)
            packets = [raw(0xfffffffe, 0xfffffffe, 2**64-10),
                       raw(0xffffffff, 0xffffffff, 2**64-5), raw(0, 0, 0), raw(1, 2, 10), raw(2, 2, 10)]
            writer.append(b''.join(p.encode() for p in packets)); writer.close()
            report = verify_session(target)
            self.assertEqual(report['streams']['RAW']['unobserved_frame_ids'], 1)
            self.assertEqual(report['streams']['RAW']['duplicate_or_backward'], 1)
            self.assertEqual(report['missing_packets'], 0)
            records = list(iter_records(target, frame_min=2**32))
            self.assertEqual([r['frame'] for r in records], [2**32, 2**32+2, 2**32+2])
            self.assertEqual(records[0]['ticks'], 2**64)
            self.assertIsNone(report['all_physical_lines_saved'])

    def test_configuration_copies_hashes_and_clip(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'session'
            writer = SessionWriter(target, index_interval=1)
            writer.event(dict(type='configuration', calibration={'source':[1, 2], 'k':[3, 4]}))
            writer.append(b''.join(raw(i).encode() for i in range(5)))
            writer.close()
            events = list(jsonlines(target/'events.jsonl'))
            self.assertIn('calibration_sha256', events[0])
            destination = Path(folder)/'clip'
            self.assertEqual(extract(target, destination, frame_min=2, frame_max=3)['selected_packets'], 2)
            self.assertEqual([r['frame'] for r in iter_records(destination)], [2, 3])
            self.assertEqual(list(jsonlines(destination/'events.jsonl'))[0]['after_packet'], 0)

    def test_slow_disk_threshold_includes_inflight_and_does_not_drop_oldest(self):
        entered, release = threading.Event(), threading.Event()
        class SlowWriter(SessionWriter):
            def append(self, chunk):
                entered.set(); release.wait(3)
                super().append(chunk)
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'session'
            size = len(raw(0).encode())
            recorder = AsyncSessionRecorder(target, queue_bytes=size*10, writer_factory=SlowWriter)
            recorder.append(raw(0).encode()); self.assertTrue(entered.wait(1))
            for i in range(1, 9):
                recorder.append(raw(i).encode())
            self.assertTrue(recorder.warning.is_set())
            self.assertTrue(recorder.stop_requested.is_set())
            self.assertEqual(recorder.queued_bytes, size*9)
            release.set(); recorder.close(device_stop_confirmed=True, stop_reason='disk_backlog')
            self.assertEqual(len(list(replay(target))), 9)

    def test_full_queue_explicit_failure(self):
        entered, release = threading.Event(), threading.Event()
        class SlowWriter(SessionWriter):
            def append(self, chunk):
                entered.set(); release.wait(3); super().append(chunk)
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'session'
            recorder = AsyncSessionRecorder(target, queue_bytes=2088, writer_factory=SlowWriter)
            recorder.append(raw(0).encode()); self.assertTrue(entered.wait(1))
            with self.assertRaises(BufferError): recorder.append(raw(1).encode())
            release.set(); recorder.close(device_stop_confirmed=True)
            status = json.loads((target/'manifest.json').read_text())
            self.assertFalse(status['closed_cleanly'])
            self.assertEqual(status['unsaved_incoming_bytes'], 2088)

    def test_disk_failure_visible_and_original_bytes_retained(self):
        class FailedWriter(SessionWriter):
            def append(self, chunk):
                super().append(chunk)
                raise OSError('simulated disk full')
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'session'
            recorder = AsyncSessionRecorder(target, writer_factory=FailedWriter)
            recorder.append(raw(0).encode())
            self.assertTrue(recorder.stop_requested.wait(1))
            with self.assertRaises(OSError): recorder.close(device_stop_confirmed=True)
            self.assertEqual((target/'stream-00000.spif').read_bytes(), raw(0).encode())
            self.assertFalse(json.loads((target/'manifest.json').read_text())['closed_cleanly'])
            self.assertTrue(json.loads((target/'failure.json').read_text())['device_stop_confirmed'])

    def test_usb_records_and_closes_only_after_stop_ack(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'session'
            worker = USBReceiver('unused', DisplayState(), record_to=target, transport_factory=FakeUSB)
            worker.start(); self.assertTrue(worker.ready.wait(1))
            worker.request_disconnect(); worker.join(2)
            self.assertFalse(worker.is_alive()); self.assertIsNone(worker.failure)
            status = json.loads((target/'manifest.json').read_text())
            self.assertTrue(status['closed_cleanly']); self.assertTrue(status['device_stop_confirmed'])
            display = DisplayState()
            replay_worker = FileReceiver(target/'manifest.json', display, speed=None)
            replay_worker.run()
            self.assertIsNone(replay_worker.failure)
            self.assertEqual(display.snapshot()['packet_count'], 2)

    def test_range_reads_only_overlapping_index_blocks(self):
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'session'
            writer = SessionWriter(target, index_interval=4)
            writer.append(b''.join(raw(i).encode() for i in range(100)))
            writer.close()
            actual_chunks = session_recording.iter_chunks
            counts = []
            def measured(*args, **kwargs):
                for chunk in actual_chunks(*args, **kwargs):
                    counts.append(len(chunk)); yield chunk
            with patch.object(session_recording, 'iter_chunks', measured):
                self.assertEqual([r['frame'] for r in iter_records(target, frame_min=41, frame_max=42)], [41, 42])
            self.assertEqual(sum(counts), 4*2088)

    def test_usb_disk_error_requests_stop_and_records_ack_status(self):
        class FailedWriter(SessionWriter):
            def append(self, chunk):
                super().append(chunk)
                raise OSError('injected disk error')
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'session'
            worker = USBReceiver('unused', DisplayState(), record_to=target, transport_factory=FakeUSB,
                                 recording_options={'writer_factory': FailedWriter})
            worker.start(); worker.join(3)
            self.assertFalse(worker.is_alive())
            self.assertTrue(worker.shutdown_confirmed.is_set())
            self.assertIn('injected disk error', worker.failure)
            self.assertTrue(json.loads((target/'failure.json').read_text())['device_stop_confirmed'])

    def test_v2_hdf5_cross_volume_and_calibration(self):
        from research_export import export_recording, _h5py
        with tempfile.TemporaryDirectory() as folder:
            target = Path(folder)/'session'
            writer = SessionWriter(target, volume_bytes=3000)
            writer.event(dict(type='acquisition', window_start=40, period_pixels=12500,
                              pixel_ticks=8, result_stride=1))
            writer.event(dict(type='configuration', calibration={'source':[1]*1024, 'k':[2, 3]}))
            writer.append(b''.join(raw(i).encode() for i in range(6))); writer.close()
            output = Path(folder)/'hdf5'
            result = export_recording(target/'manifest.json', output)
            self.assertTrue(result['integrity_ok']); self.assertEqual(result['spectra_rows'], 6)
            with _h5py().File(output/'research.h5') as stream:
                self.assertEqual(list(stream['spectra/frame_id'][:]), list(range(6)))
                self.assertEqual(list(stream['spectra/window_start'][:]), [40]*6)
                self.assertEqual(len(stream['calibration/v2_1/source']), 1024)


if __name__ == '__main__':
    unittest.main()
