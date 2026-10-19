import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from host.protocol import Packet,Kind,NO_FRAME,Decoder

data=bytes.fromhex(Path(sys.argv[1]).read_text())
# Exact byte comparison independently verifies header fields, snapshots and CRC.
expected=b''.join(Packet(Kind.ACK,i,NO_FRAME,(11+i).to_bytes(4,'little')+bytes(4),
                         source_version=(2 if i>=2 else 1),k_version=(2 if i==3 else min(i,1))).encode() for i in range(4))
assert data==expected, 'ACK bytes differ from host codec'
decoder=Decoder()
packets=[]
for byte in data:
    packets.extend(decoder.feed(bytes([byte])))
assert len(packets)==4
print('PASS: applied ACK bytes/CRC/version snapshots match host codec, fragmented decoding')
