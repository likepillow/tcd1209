from pathlib import Path
import struct
import sys
import tempfile
import threading
import time
import unittest

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'host'))
from live_receiver import USBReceiver
from protocol import (Decoder, Kind, NO_FRAME, Packet, TIME_VALID, run_command)
from receiver import ReplayPacer
from recording import Recorder
from usb_transport import Transfer
from workbench import DisplayState


class FakeUSB:
    instances = []

    def __init__(self, _dll):
        self.responses = []
        self.writes = []
        self.packet_sequence = 0
        FakeUSB.instances.append(self)

    def __enter__(self):
        return self

    def __exit__(self, *_):
        pass

    def write(self, wire):
        command = list(Decoder().feed(wire))[0]
        self.writes.append(command)
        payload = struct.pack('<IHH', command.sequence, 0, 0)
        ack = Packet(Kind.ACK, self.packet_sequence, NO_FRAME, payload).encode()
        self.packet_sequence += 1
        self.responses.append(ack)
        return Transfer(True, len(wire), 0)

    def read(self):
        if self.responses:
            data = self.responses.pop(0)
            return Transfer(True, len(data), 0, data)
        time.sleep(.001)
        return Transfer(False, 0, 121, b'', elapsed_ms=200)


class RunControlTests(unittest.TestCase):
    def test_wire_rejects_non_boolean_and_noncanonical_payload(self):
        self.assertEqual(struct.unpack('<I', run_command(True, 7).payload)[0], 1)
        with self.assertRaises(TypeError):
            run_command(1, 7)
        with self.assertRaises(ValueError):
            Packet(Kind.RUN_CONTROL, 0, NO_FRAME, struct.pack('<I', 2)).encode()

    def test_usb_prepares_stopped_then_starts_stops_and_disconnects(self):
        FakeUSB.instances.clear()
        display = DisplayState()
        worker = USBReceiver('ignored', display, transport_factory=FakeUSB)
        worker.start()
        self.assertTrue(worker.ready.wait(1))
        self.assertFalse(worker.run_state)
        worker.start_acquisition()
        deadline = time.monotonic()+1
        while worker.run_state is not True and time.monotonic() < deadline:
            time.sleep(.002)
        self.assertTrue(worker.run_state)
        worker.stop_acquisition()
        deadline = time.monotonic()+1
        while worker.run_state is not False and time.monotonic() < deadline:
            time.sleep(.002)
        self.assertFalse(worker.run_state)
        worker.request_disconnect()
        worker.join(1)
        self.assertFalse(worker.is_alive())
        self.assertTrue(worker.shutdown_confirmed.is_set())
        self.assertEqual([struct.unpack('<I', p.payload)[0] for p in FakeUSB.instances[0].writes],
                         [0, 1, 0, 0])

    def test_run_events_persist_and_display_inserts_gap(self):
        display = DisplayState()
        display.set_running(True)
        result_payload = bytes(12)+struct.pack('<hHHHII', 0, 1, 1, 1, 0, 0)
        display.ingest(Packet(Kind.RESULT, 0, 1, result_payload, flags=0))
        display.set_running(False)
        display.set_running(True)
        display.ingest(Packet(Kind.RESULT, 1, 2, result_payload, flags=0))
        self.assertTrue(display.snapshot()['history'][1][3])
        with tempfile.TemporaryDirectory() as folder:
            with Recorder(Path(folder)/'record') as recorder:
                recorder.run_state_changed(False)
                recorder.run_state_changed(True)
            import json
            metadata = json.loads((Path(folder)/'record'/'manifest.json').read_text('utf-8'))['metadata']
            self.assertEqual([e['running'] for e in metadata['run_events']], [False, True])

    def test_replay_speed_uses_timestamp_and_unlimited_does_not_wait(self):
        first = Packet(Kind.RAW, 0, 1, np.zeros(1024, '<u2').tobytes(), 100, flags=TIME_VALID)
        second = Packet(Kind.RAW, 1, 2, np.zeros(1024, '<u2').tobytes(), 5_000_100, flags=TIME_VALID)
        stop = threading.Event()
        pacer = ReplayPacer(4)
        pacer.pace(first, stop)
        before = time.monotonic()
        pacer.pace(second, stop)
        self.assertGreater(time.monotonic()-before, .008)
        pacer = ReplayPacer(None)
        pacer.pace(first, stop)
        before = time.monotonic()
        pacer.pace(second, stop)
        self.assertLess(time.monotonic()-before, .01)


if __name__ == '__main__':
    unittest.main()
