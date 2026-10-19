import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host.protocol import Packet, Kind, Decoder, DISCONTINUITY

actual = bytes.fromhex(Path(sys.argv[1]).read_text())
expected = b''
for i, frame in enumerate([0xfffffffe, 0xffffffff, 0, 2, 3]):
    payload = b''.join(((n * 73 + 19) % 4096).to_bytes(2, 'little')
                       for n in range(i * 1024, (i + 1) * 1024))
    expected += Packet(Kind.RAW, i, frame, payload,
                       flags=DISCONTINUITY if i == 3 else 0).encode()
assert actual == expected, 'RAW stream payload/sequence/continuity/CRC mismatch'
decoder = Decoder()
packets = []
for offset in range(0, len(actual), 37):
    packets.extend(decoder.feed(actual[offset:offset + 37]))
assert len(packets) == 5
print('PASS: five RAW stream frames, wrap continuity and gap flag match host codec')
