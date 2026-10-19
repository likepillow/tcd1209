import math
from pathlib import Path
import random
import struct
import sys
import unittest
import zlib

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'host'))
from protocol import (CRC, HEADER, INVALID, TIME_VALID, MAX_PACKET, Kind, Packet,
                      Decoder, DistanceResult, SequenceTracker, SPECTRUM_DTYPE,
                      RESULT_TAIL, source_command, k_command, export_command)
from reference import Calibration


def crc_bitwise(data):
    value = 0xffffffff
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = (value >> 1) ^ (0xedb88320 if value & 1 else 0)
    return value ^ 0xffffffff


def result_packet(acc, exponent=76, flags=0, seq=0):
    payload = acc.to_bytes(12, 'little', signed=True)
    payload += RESULT_TAIL.pack(exponent, 43, 40, 47, 17, 3)
    return Packet(Kind.RESULT, seq, 200, payload, 100000, 0x12345678, 0xfedcba98, flags | TIME_VALID)


class ProtocolTests(unittest.TestCase):
    def test_export_command(self):
        for period in (0, 1, 2, 100, 0xffffffff):
            packet = export_command(period, 73)
            decoded = list(Decoder().feed(packet.encode()))
            self.assertEqual(decoded, [packet])
            self.assertEqual(packet.payload, struct.pack('<I', period))
        for period in (-1, 2**32, 1.5):
            with self.assertRaises(ValueError):
                export_command(period, 73)

    def test_header_layout_crc_and_signed_84(self):
        self.assertEqual(HEADER.size, 36)
        self.assertEqual(crc_bitwise(b'123456789'), 0xcbf43926)
        for acc in (-2**83, -2**70-17, 0, 2**83-1):
            p = result_packet(acc, seq=0xdeadbeef)
            wire = p.encode()
            self.assertEqual(wire[:20], bytes.fromhex('53504946 01 13 0400 1c000000 efbeadde c8000000'))
            self.assertEqual(wire[28:36], bytes.fromhex('78563412 98badcfe'))
            self.assertEqual(CRC.unpack(wire[-4:])[0], crc_bitwise(wire[:-4]))
            d = Decoder()
            decoded = list(d.feed(wire))
            d.finish()
            self.assertEqual(decoded, [p])
            r = DistanceResult.from_packet(decoded[0])
            self.assertEqual(r.accumulator, acc)
            self.assertEqual(r.distance, math.ldexp(acc, -76))
            self.assertEqual((r.dropped_frames, r.malformed_frames), (17, 3))
        self.assertTrue(math.isnan(DistanceResult.from_packet(result_packet(1, flags=INVALID)).distance))
        for exponent in (-32768, 32767):
            with self.assertRaises(ValueError):
                _ = DistanceResult.from_packet(result_packet(1, exponent)).distance

    def packets(self):
        raw = np.arange(1024, dtype='<u2').tobytes()
        a = np.zeros(1024, dtype=SPECTRUM_DTYPE)
        a['s0'] = 4095
        a['s1'] = 2**24-1
        a['s2'][::2] = -2**24
        a['s2'][1::2] = 2**24-1
        phase = np.resize(np.array([-2**42, 2**42-1], dtype='<i8'), 1024).tobytes()
        cal = Calibration.create(np.full(1024, 2048), np.linspace(1e7, 1.1e7, 1024))
        return [Packet(Kind.RAW, 0, 9, raw), Packet(Kind.SPECTRUM, 1, 8, a.tobytes()),
                Packet(Kind.PHASE, 2, 8, phase), result_packet(-2**72, seq=3),
                source_command(cal.source, 4), k_command(cal, 5),
                Packet(Kind.ACK, 6, 0xffffffff, struct.pack('<IHH', 4, 0, 0))]

    def test_every_type_and_fragment_boundary(self):
        packets = self.packets()
        wire = b''.join(p.encode() for p in packets)
        for chunk in (1, 3, 35, 36, 37, 64, 512, 4096, len(wire)):
            decoder = Decoder()
            output = []
            for pos in range(0, len(wire), chunk):
                output.extend(decoder.feed(wire[pos:pos+chunk]))
                self.assertLessEqual(len(decoder.buffer), MAX_PACKET)
            decoder.finish()
            self.assertEqual(output, packets)
            self.assertEqual(decoder.discarded_bytes, 0)

    def test_corruption_resync_and_bounded_noise(self):
        packets = self.packets()
        wire = bytearray(packets[0].encode())
        wire[HEADER.size+99] ^= 1
        bad_header = bytearray(packets[1].encode())
        bad_header[8:12] = b'\xff'*4
        noise = b'x'*(3*MAX_PACKET)+b'SP'
        data = noise+bytes(wire)+bytes(bad_header)+packets[2].encode()+packets[3].encode()
        d = Decoder()
        rng = random.Random(1209)
        output = []
        pos = 0
        while pos < len(data):
            size = rng.randint(1, 800)
            output.extend(d.feed(data[pos:pos+size]))
            self.assertLessEqual(len(d.buffer), MAX_PACKET)
            pos += size
        d.finish()
        self.assertEqual(output, packets[2:4])
        self.assertEqual(d.bad_crc, 1)
        self.assertEqual(d.bad_headers, 1)
        self.assertEqual(d.discarded_bytes, len(noise)+len(wire)+len(bad_header))

    def test_truncated_tail_is_not_silent_success(self):
        wire = result_packet(34).encode()
        for length in (1, 3, 10, 35, 36, len(wire)-1):
            d = Decoder()
            self.assertEqual(list(d.feed(wire[:length])), [])
            with self.assertRaises(ValueError):
                d.finish()

    def test_crc_valid_but_illegal_numeric_payload_rejected(self):
        wire = bytearray(self.packets()[0].encode())
        struct.pack_into('<H', wire, HEADER.size, 4096)
        struct.pack_into('<I', wire, len(wire)-4, zlib.crc32(wire[:-4]))
        d = Decoder()
        self.assertEqual(list(d.feed(wire)), [])
        self.assertEqual(d.bad_payloads, 1)
        d.finish()
        with self.assertRaises(ValueError):
            result_packet(2**83).encode()
        with self.assertRaises(ValueError):
            Packet(Kind.RAW, 0, 0, bytes(2048), timestamp=10).encode()
        with self.assertRaises(ValueError):
            Packet(Kind.PHASE, 0, 0, np.full(1024, 2**42, dtype='<i8').tobytes()).encode()
        with self.assertRaises(ValueError):
            Packet(Kind.K_WEIGHTS, 0, 0, bytes(4)+np.ones(512, dtype='<i4').tobytes()).encode()

    def test_calibration_commands_match_rtl_contract(self):
        cal = Calibration.create(np.full(1024, 2048), np.arange(512))
        s = source_command(cal.source, 41)
        self.assertTrue(np.all(np.frombuffer(s.payload, '<u4') == 2**19))
        k = k_command(cal, 42)
        self.assertEqual(int(np.frombuffer(k.payload, '<i4', offset=4).astype(np.int64).sum()), 0)
        self.assertGreater(struct.unpack_from('<h', k.payload)[0], 0)
        s.encode()
        k.encode()

    def test_sequence_gaps_duplicates_out_of_order_and_wrap(self):
        tracker = SequenceTracker()
        for seq in (0xfffffffe, 0xffffffff, 0, 3):
            self.assertTrue(tracker.observe(seq))
        self.assertEqual(tracker.missing, 2)
        self.assertFalse(tracker.observe(3))
        self.assertFalse(tracker.observe(2))
        self.assertEqual(tracker.previous, 3)
        self.assertTrue(tracker.observe(4))
        self.assertEqual(tracker.out_of_order, 2)


if __name__ == '__main__':
    unittest.main()
