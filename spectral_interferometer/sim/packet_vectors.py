"""Generate byte-exact RTL vectors using the host protocol and all seven kinds."""
from pathlib import Path
import sys
from test_protocol import ProtocolTests

output = Path(sys.argv[1])
output.mkdir(parents=True, exist_ok=True)
packets = ProtocolTests().packets()
data = b''.join(p.encode() for p in packets)
(output/'packet_bytes.mem').write_text(''.join(f'{v:02x}\n' for v in data), encoding='ascii')
(output/'packet_count.vh').write_text(f'`define BYTE_COUNT {len(data)}\n`define PACKET_COUNT {len(packets)}\n', encoding='ascii')
print(f'Generated {len(packets)} packets, {len(data)} bytes')
