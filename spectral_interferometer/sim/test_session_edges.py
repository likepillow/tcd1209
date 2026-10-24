"""Deterministic replay timing and safe-disconnect failure-path coverage."""
import json
from pathlib import Path
import struct
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from live_receiver import USBReceiver
from protocol import Kind, Packet, TIME_VALID, export_command
from receiver import FileReceiver, ReplayPacer
from acquisition_settings import AcquisitionSettings
from recording import Recorder
from session_recording import jsonlines
from workbench import DisplayState
from test_run_control import FakeUSB


class VirtualClock:
    def __init__(self):
        self.now = 0.0
        self.waits = []

    def __call__(self):
        return self.now

    def clear(self):
        pass

    def set(self):
        pass

    def wait(self, seconds):
        self.waits.append(seconds)
        self.now += seconds


class HeldUSB(FakeUSB):
    """Hold an already-written ordinary command until the test releases it."""
    def __init__(self, dll):
        super().__init__(dll)
        self.held = threading.Event()
        self.release = threading.Event()

    def write(self, wire):
        result = super().write(wire)
        if self.writes[-1].kind == Kind.EXPORT:
            self.held.set()
        return result

    def read(self):
        if self.held.is_set() and not self.release.is_set():
            self.release.wait(.01)
            if not self.release.is_set():
                from usb_transport import Transfer
                return Transfer(False, 0, 121, b'', elapsed_ms=200)
        return super().read()


class MissingStopUSB(FakeUSB):
    def write(self, wire):
        result = super().write(wire)
        if len(self.writes) > 1:
            self.responses.clear()  # Initial synchronization succeeds, shutdown does not.
        return result


class SessionEdgeTests(unittest.TestCase):
    def pacer(self, speed=1):
        clock = VirtualClock()
        pacer = ReplayPacer(speed, clock=clock)
        pacer._wake = clock
        return pacer, clock

    def raw(self, frame, ticks=0, flags=TIME_VALID):
        return Packet(Kind.RAW, frame, frame, bytes(2048), ticks, flags=flags)

    def test_all_speed_multipliers_and_true_stop_gap(self):
        for speed in (.25, .5, 1, 2, 4):
            with self.subTest(speed=speed):
                pacer, clock = self.pacer(speed)
                stop = threading.Event()
                pacer.pace(self.raw(1, 100), stop)
                pacer.pace(self.raw(2, 200_000_100), stop)
                self.assertAlmostEqual(clock.now, 2 / speed, places=8)
                # Same-frame packets add no delay, even after a real acquisition gap.
                waits = len(clock.waits)
                pacer.pace(self.raw(2, 200_000_100), stop)
                self.assertEqual(len(clock.waits), waits)

    def test_dynamic_speed_reanchors_and_unlimited_keeps_packets(self):
        pacer, clock = self.pacer()
        stop = threading.Event()
        pacer.pace(self.raw(1, 0), stop)
        pacer.pace(self.raw(2, 100_000_000), stop)
        clock.now += 20  # UI activity must not cause catch-up after a speed change.
        pacer.set_speed(2)
        pacer.pace(self.raw(3, 200_000_000), stop)
        self.assertAlmostEqual(clock.now, 21.5)
        pacer.set_speed(None)
        waits = len(clock.waits)
        for frame in range(4, 20):
            pacer.pace(self.raw(frame, frame * 100_000_000), stop)
        self.assertEqual(len(clock.waits), waits)
        self.assertEqual(pacer._last_ticks, 19 * 100_000_000)

    def test_legacy_period_fallback_frame_delta_and_wrap(self):
        for period in (2114, 3000):
            pacer, clock = self.pacer()
            pacer.set_period(period)
            stop = threading.Event()
            pacer.pace(self.raw(0xfffffffe, flags=0), stop)
            pacer.pace(self.raw(1, flags=0), stop)
            self.assertAlmostEqual(clock.now, 3 * period * 20 / 1e8)
            self.assertTrue(pacer.estimated)

    def test_manifest_period_replay_and_same_connection_run_events(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            record = root / 'legacy'
            with Recorder(record) as recorder:
                recorder.acquisition_applied(AcquisitionSettings(40, 3000))
                recorder.append(self.raw(1, flags=0).encode())
                recorder.append(self.raw(2, flags=0).encode())
            display = DisplayState()
            replay = FileReceiver(record / 'stream.spif', display)
            replay.pacer, clock = self.pacer()
            replay.run()
            self.assertIsNone(replay.failure)
            self.assertAlmostEqual(clock.now, .0006)
            self.assertTrue(replay.pacer.estimated)

            live_record = root / 'live'
            worker = USBReceiver('fake', DisplayState(), record_to=live_record,
                                 transport_factory=FakeUSB)
            worker.start()
            self.assertTrue(worker.ready.wait(1))
            try:
                for desired in (True, False, True, False):
                    worker.start_acquisition() if desired else worker.stop_acquisition()
                    deadline = time.monotonic() + 1
                    while True:
                        event = worker.events.get(timeout=max(.001, deadline-time.monotonic()))
                        if event[:3] == ('run', desired, 'user'):
                            break
                worker.request_disconnect()
            finally:
                worker.request_disconnect()
                worker.join(2)
            self.assertTrue(worker.shutdown_confirmed.is_set())
            manifest = json.loads((live_record / 'manifest.json').read_text('utf-8'))
            self.assertEqual([e['running'] for e in jsonlines(live_record/'events.jsonl') if e['type'] == 'run'],
                             [False, True, False, True, False, False])
            self.assertEqual(len(list(root.glob('live/manifest.json'))), 1)

    def test_disconnect_waits_sent_command_and_cancels_unsent(self):
        FakeUSB.instances.clear()
        with tempfile.TemporaryDirectory() as folder:
            record = Path(folder) / 'session'
            worker = USBReceiver('fake', DisplayState(), record_to=record,
                                 transport_factory=HeldUSB)
            worker.start()
            self.assertTrue(worker.ready.wait(1))
            usb = FakeUSB.instances[-1]
            try:
                worker.submit(export_command(10, 0))
                self.assertTrue(usb.held.wait(1))
                worker.submit(export_command(20, 0))
                worker.request_disconnect()
                self.assertFalse(worker.shutdown_confirmed.is_set())
                self.assertEqual(len(usb.writes), 2)
            finally:
                worker.request_disconnect()
                usb.release.set()
                worker.join(2)
            self.assertFalse(worker.is_alive())
            self.assertIsNone(worker.failure)
            self.assertTrue(worker.shutdown_confirmed.is_set())
            self.assertEqual([p.kind for p in usb.writes],
                             [Kind.RUN_CONTROL, Kind.EXPORT, Kind.RUN_CONTROL])
            self.assertEqual(struct.unpack('<I', usb.writes[1].payload)[0], 10)
            manifest = json.loads((record / 'manifest.json').read_text('utf-8'))
            self.assertEqual([e['running'] for e in jsonlines(record/'events.jsonl') if e['type'] == 'run'],
                             [False, False])

    def test_stop_ack_timeout_does_not_confirm_shutdown_or_close_window(self):
        worker = USBReceiver('fake', DisplayState(), transport_factory=MissingStopUSB)
        worker.ACK_TIMEOUT = .03
        worker.start()
        self.assertTrue(worker.ready.wait(1))
        worker.request_disconnect()
        worker.join(1)
        self.assertFalse(worker.is_alive())
        self.assertFalse(worker.shutdown_confirmed.is_set())
        self.assertIn('acknowledgement timeout', worker.failure)
        self.assertEqual(worker.state, '停机未确认')
        from viewer import Viewer
        viewer = Viewer.__new__(Viewer)
        viewer.worker = worker
        viewer.root = Mock()
        with patch('viewer.messagebox.askyesno', return_value=False) as warning:
            viewer.close()
        warning.assert_called_once()
        viewer.root.destroy.assert_not_called()


if __name__ == '__main__':
    unittest.main()
