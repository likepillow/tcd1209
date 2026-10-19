import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host.protocol import Packet, Kind, Decoder, DISCONTINUITY
actual = bytes.fromhex(Path(sys.argv[1]).read_text())
frames = [0, 1, 4, 5] if '--long-stall' in sys.argv else list(range(6))
expected = b''.join(Packet(Kind.RAW, sequence, f, b''.join(
    ((f * 211 + p * 13 + 7) % 4096).to_bytes(2, 'little')
    for p in range(512, 1536)), flags=DISCONTINUITY if sequence and f!=frames[sequence-1]+1 else 0).encode()
    for sequence, f in enumerate(frames))
assert actual == expected, 'capture crop/pixel/frame/header/CRC mismatch'
decoder = Decoder()
packets = []
for i in range(0, len(actual), 113):
    packets.extend(decoder.feed(actual[i:i+113]))
assert len(packets) == len(frames)
print(f'PASS: captured frames {frames} match host codec, crop and discontinuity exactly')
