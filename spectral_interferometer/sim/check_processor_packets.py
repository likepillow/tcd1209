import sys
import csv
import struct
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host.protocol import Packet, Kind, DISCONTINUITY, INVALID, TIME_VALID, Decoder, RESULT_TAIL
root = Path(sys.argv[1])
raw = [int(v, 16) for v in (root / 'processor_raw.mem').read_text().split()]
with (root / 'processor_results.csv').open() as stream:
    results = {int(row[0]): row for row in csv.reader(stream)}
with (root / 'processor_spectrum.csv').open() as stream:
    spectra = {}
    for row in csv.reader(stream):
        frame, index, s0, s1, s2 = map(int, row)
        spectra.setdefault(frame, bytearray()).extend(struct.pack('<HIi', s0, s1, s2))
actual = bytes.fromhex((root / 'processor_raw_packets.hex').read_text())
decoder = Decoder()
decoded = []
for i in range(0, len(actual), 113):
    decoded.extend(decoder.feed(actual[i:i+113]))
assert len(decoded) == 10
expected = b''
raw_frames, result_frames = [], []
spectrum_frames = []
ack_count = 0
for sequence, packet in enumerate(decoded):
    assert packet.sequence == sequence
    frame = packet.frame_id
    if packet.kind == Kind.RAW:
        assert frame in [198, 200, 201, 202, 203]
        pixels = [777] * 1024 if frame == 198 else raw[(frame-200)*1024:(frame-199)*1024]
        reference = Packet(Kind.RAW, sequence, frame,
                           b''.join(p.to_bytes(2, 'little') for p in pixels),
                           timestamp=100000 + frame * 17002,
                           flags=TIME_VALID | (DISCONTINUITY if frame != 198 else 0))
        raw_frames.append(frame)
    elif packet.kind == Kind.SPECTRUM:
        assert frame in spectra
        reference = Packet(Kind.SPECTRUM, sequence, frame, bytes(spectra[frame]), source_version=1)
        spectrum_frames.append(frame)
    elif packet.kind == Kind.ACK:
        reference = Packet(Kind.ACK, sequence, 0xffffffff, struct.pack('<IHH', 11 + ack_count, 0, 0),
                           source_version=1, k_version=min(ack_count, 1))
        ack_count += 1
    else:
        assert packet.kind == Kind.RESULT and frame in results
        row = results[frame]
        accumulator = int(row[1], 16)
        if accumulator >= 2**83:
            accumulator -= 2**84
        exponent, invalid, peak, left, right, sv, kv = map(int, row[2:])
        payload = accumulator.to_bytes(12, 'little', signed=True) + RESULT_TAIL.pack(exponent, peak, left, right, 0, 0)
        reference = Packet(Kind.RESULT, sequence, frame, payload, source_version=sv, k_version=kv,
                           timestamp=100000 + frame * 17002,
                           flags=TIME_VALID | (INVALID if invalid else 0))
        result_frames.append(frame)
    expected += reference.encode()
assert raw_frames == [198, 201, 203]
assert result_frames == [200, 201, 202, 203]
assert spectrum_frames == [], 'S1/S2 must stay internal in S0-only export mode'
assert ack_count == 3
assert actual == expected, 'DSP concurrent packet bytes/metadata/CRC mismatch'
print('PASS: S/K/EXPORT upload, three ACKs, three selected RAW and all four DSP RESULT packets; no S1/S2 export')
