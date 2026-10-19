"""SPIF v1 wire codec shared by USB transport, recordings and simulation.

All fields are little-endian. CRC-32/ISO-HDLC covers header and payload.
Keep this module free of USB/GUI dependencies so saved bytes use the same parser.
"""
from dataclasses import dataclass
from enum import IntEnum
import math
import struct
import zlib

import numpy as np

MAGIC = b'SPIF'
VERSION = 1
HEADER = struct.Struct('<4sBBHIIIQII')  # 36 bytes
CRC = struct.Struct('<I')
INVALID = 1
DISCONTINUITY = 2
TIME_VALID = 4
FLAGS_MASK = 7
NO_FRAME = 0xffffffff


class Kind(IntEnum):
    RAW = 0x10
    SPECTRUM = 0x11
    PHASE = 0x12
    RESULT = 0x13
    SOURCE = 0x20
    K_WEIGHTS = 0x21
    ACK = 0x22
    EXPORT = 0x23
    ACQUISITION = 0x24
    RUN_CONTROL = 0x25


LENGTHS = {Kind.RAW: 2048, Kind.SPECTRUM: 10240, Kind.PHASE: 8192,
           Kind.RESULT: 28, Kind.SOURCE: 4096, Kind.K_WEIGHTS: 2052, Kind.ACK: 8,
           Kind.EXPORT: 4, Kind.ACQUISITION: 8, Kind.RUN_CONTROL: 4}
MAX_PACKET = HEADER.size + max(LENGTHS.values()) + CRC.size
SPECTRUM_DTYPE = np.dtype([('s0', '<u2'), ('s1', '<u4'), ('s2', '<i4')])
RESULT_TAIL = struct.Struct('<hHHHII')


def _uint(value, bits, name):
    if not isinstance(value, int) or not 0 <= value < 2**bits:
        raise ValueError(f'{name} must be unsigned {bits}-bit')
    return value


def export_command(period_frames, sequence):
    """Set S0 selection period: zero disables; N exports one opportunity in N.

    ACK confirms the register update; selection changes at the next frame start.
    This does not change the acquisition or distance-calculation frame rate.
    """
    return Packet(Kind.EXPORT, sequence, NO_FRAME,
                  struct.pack('<I', _uint(period_frames, 32, 'period_frames')))


def acquisition_command(settings, sequence):
    """Request atomic W/T change; requires matching acquisition-control firmware."""
    from acquisition_settings import AcquisitionSettings
    if not isinstance(settings, AcquisitionSettings):
        raise TypeError('Expected AcquisitionSettings')
    return Packet(Kind.ACQUISITION, sequence, NO_FRAME, settings.encode())


def run_command(running, sequence):
    """Start or gracefully stop acquisition without changing calibration."""
    if not isinstance(running, bool):
        raise TypeError('running must be bool')
    return Packet(Kind.RUN_CONTROL, sequence, NO_FRAME,
                  struct.pack('<I', int(running)))


@dataclass(frozen=True)
class Packet:
    kind: Kind
    sequence: int
    frame_id: int
    payload: bytes
    timestamp: int = 0
    source_version: int = 0
    k_version: int = 0
    flags: int = 0

    def encode(self):
        kind = Kind(self.kind)
        if self.flags & ~FLAGS_MASK or self.flags < 0:
            raise ValueError('Unknown flags')
        if not self.flags & TIME_VALID and self.timestamp != 0:
            raise ValueError('Timestamp requires TIME_VALID')
        payload = bytes(self.payload)
        validate_payload(kind, payload)
        head = HEADER.pack(MAGIC, VERSION, kind, self.flags, len(payload),
                           _uint(self.sequence, 32, 'sequence'),
                           _uint(self.frame_id, 32, 'frame_id'),
                           _uint(self.timestamp, 64, 'timestamp'),
                           _uint(self.source_version, 32, 'source_version'),
                           _uint(self.k_version, 32, 'k_version'))
        body = head + payload
        return body + CRC.pack(zlib.crc32(body))


def validate_payload(kind, payload):
    """Reject noncanonical sign extension, invalid coefficients and bad lengths."""
    kind = Kind(kind)
    if len(payload) != LENGTHS[kind]:
        raise ValueError(f'{kind.name} payload length must be {LENGTHS[kind]}')
    if kind == Kind.RAW:
        if np.any(np.frombuffer(payload, '<u2') > 4095):
            raise ValueError('RAW exceeds unsigned 12-bit ADC range')
    elif kind == Kind.SPECTRUM:
        a = np.frombuffer(payload, SPECTRUM_DTYPE)
        if (np.any(a['s0'] > 4095) or np.any(a['s1'] >= 2**24)
                or np.any(a['s2'] < -2**24) or np.any(a['s2'] >= 2**24)):
            raise ValueError('SPECTRUM exceeds RTL ranges')
    elif kind == Kind.PHASE:
        a = np.frombuffer(payload, '<i8')
        if np.any(a < -2**42) or np.any(a >= 2**42):
            raise ValueError('PHASE is not sign-extended signed 43-bit')
    elif kind == Kind.RESULT:
        value = int.from_bytes(payload[:12], 'little', signed=True)
        if not -2**83 <= value < 2**83:
            raise ValueError('RESULT is not sign-extended signed 84-bit')
        _, peak, left, right, _, _ = RESULT_TAIL.unpack_from(payload, 12)
        # No-peak invalid frames may report all-zero band metadata.
        if (peak, left, right) != (0, 0, 0) and not 1 <= left <= peak <= right <= 511:
            raise ValueError('RESULT has invalid positive-frequency band')
    elif kind == Kind.SOURCE:
        a = np.frombuffer(payload, '<u4')
        if np.any(a < 1) or np.any(a > 2**30):
            raise ValueError('SOURCE reciprocal must be 1..2^30')
    elif kind == Kind.K_WEIGHTS:
        _, reserved = struct.unpack_from('<hH', payload)
        a = np.frombuffer(payload, '<i4', offset=4)
        if reserved or int(a.astype(np.int64).sum()) != 0:
            raise ValueError('K_WEIGHTS needs zero reserved field and exact zero sum')
    elif kind == Kind.ACK:
        _, status, reserved = struct.unpack('<IHH', payload)
        if reserved or status > 4:
            raise ValueError('ACK has unknown status/reserved field')
    elif kind == Kind.ACQUISITION:
        from acquisition_settings import AcquisitionSettings
        AcquisitionSettings.decode(payload)
    elif kind == Kind.RUN_CONTROL:
        if struct.unpack('<I', payload)[0] > 1:
            raise ValueError('RUN_CONTROL must be zero or one')


@dataclass(frozen=True)
class DistanceResult:
    accumulator: int
    exponent: int
    peak: int
    left: int
    right: int
    dropped_frames: int
    malformed_frames: int
    invalid: bool

    @property
    def distance(self):
        if self.invalid:
            return math.nan
        try:
            value = math.ldexp(self.accumulator, -self.exponent)
        except OverflowError as error:
            raise ValueError('Distance exceeds host floating-point range') from error
        if not math.isfinite(value):
            raise ValueError('Nonfinite distance')
        if value == 0 and self.accumulator != 0:
            raise ValueError('Nonzero distance underflows host floating-point range')
        return value

    @classmethod
    def from_packet(cls, packet):
        if packet.kind != Kind.RESULT:
            raise ValueError('Expected RESULT packet')
        validate_payload(packet.kind, packet.payload)
        if not packet.flags & INVALID and RESULT_TAIL.unpack_from(packet.payload, 12)[1] == 0:
            raise ValueError('A no-peak result must be marked invalid')
        return cls(int.from_bytes(packet.payload[:12], 'little', signed=True),
                   *RESULT_TAIL.unpack_from(packet.payload, 12), bool(packet.flags & INVALID))


class Decoder:
    """Incremental resynchronizing decoder; retained buffer <= MAX_PACKET.

    feed yields packets, so callers can write/process them without accumulating a
    whole USB transfer in memory. A damaged packet is counted and NEVER returned.
    finish detects an incomplete trailing header/payload in recordings.
    """
    def __init__(self):
        self.buffer = bytearray()
        self.discarded_bytes = 0
        self.bad_headers = 0
        self.bad_crc = 0
        self.bad_payloads = 0
        self.packets = 0

    def feed(self, data):
        incoming = memoryview(data).cast('B')
        position = 0
        while position < len(incoming):
            count = min(MAX_PACKET-len(self.buffer), len(incoming)-position)
            if count <= 0:
                raise RuntimeError('Decoder failed to make progress')
            self.buffer.extend(incoming[position:position+count])
            position += count
            yield from self._drain()

    def _discard(self, count):
        del self.buffer[:count]
        self.discarded_bytes += count

    def _drain(self):
        while True:
            start = self.buffer.find(MAGIC)
            if start < 0:
                self._discard(max(0, len(self.buffer)-3))
                return
            if start:
                self._discard(start)
            if len(self.buffer) < HEADER.size:
                return
            _, version, kind, flags, size, seq, frame, time, sv, kv = HEADER.unpack_from(self.buffer)
            if (version != VERSION or kind not in LENGTHS or size != LENGTHS.get(kind)
                    or flags & ~FLAGS_MASK or (not flags & TIME_VALID and time != 0)):
                self.bad_headers += 1
                self._discard(1)
                continue
            total = HEADER.size+size+CRC.size
            if len(self.buffer) < total:
                return
            body = bytes(self.buffer[:total-CRC.size])
            if zlib.crc32(body) != CRC.unpack_from(self.buffer, total-CRC.size)[0]:
                self.bad_crc += 1
                self._discard(1)
                continue
            payload = body[HEADER.size:]
            try:
                validate_payload(kind, payload)
            except ValueError:
                self.bad_payloads += 1
                self._discard(total)
                continue
            del self.buffer[:total]
            self.packets += 1
            yield Packet(Kind(kind), seq, frame, payload, time, sv, kv, flags)

    def finish(self):
        if self.buffer:
            raise ValueError(f'Incomplete/trailing data: {len(self.buffer)} bytes')


class SequenceTracker:
    """Global device-to-host packet sequence, independent of frame IDs/types.

    A reset starts a new recording/tracker. Backward/duplicate packets do not
    move the high-water mark and cannot masquerade as billions of missing ones.
    """
    def __init__(self):
        self.previous = None
        self.missing = 0
        self.out_of_order = 0

    def observe(self, sequence):
        sequence = _uint(sequence, 32, 'sequence')
        if self.previous is not None:
            delta = (sequence-self.previous) & 0xffffffff
            if delta == 0 or delta >= 2**31:
                self.out_of_order += 1
                return False
            self.missing += delta-1
        self.previous = sequence
        return True


def source_command(source, sequence):
    from fixed import reciprocal_q30
    payload = reciprocal_q30(source).astype('<u4').tobytes()
    return Packet(Kind.SOURCE, sequence, NO_FRAME, payload)


def k_command(calibration, sequence):
    from fixed import FixedFit
    fit = FixedFit.from_calibration(calibration)
    if not -2**15 <= fit.exponent < 2**15:
        raise ValueError('K exponent exceeds RTL signed 16-bit range')
    payload = struct.pack('<hH', fit.exponent, 0)+fit.weights.astype('<i4').tobytes()
    return Packet(Kind.K_WEIGHTS, sequence, NO_FRAME, payload)
