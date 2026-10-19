import struct
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host.protocol import Packet, Kind, TIME_VALID, Decoder
payload = b''.join(struct.pack('<HIi', (n*17) % 4096, 0xffffff-n*123,
                              0xffffff-n if n % 2 else -16777216+n) for n in range(1024))
expected = Packet(Kind.SPECTRUM, 5, 123, payload, timestamp=987654, source_version=7, flags=TIME_VALID).encode()
actual = bytes.fromhex(Path(sys.argv[1]).read_text())
assert actual == expected, 'S0/S1/S2 serialization or metadata/CRC mismatch'
decoder = Decoder()
decoded = []
for i in range(0, len(actual), 37):
    decoded.extend(decoder.feed(actual[i:i+37]))
assert len(decoded) == 1 and decoded[0].payload == payload
print('PASS: spectrum signed extremes, metadata, CRC and fragmented decode')
