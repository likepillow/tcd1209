"""Generate independent host-codec vectors for the RTL config receiver."""
import sys
import zlib
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from host.protocol import Packet, Kind, NO_FRAME

out=Path(sys.argv[1])
source=b''.join((1+i*1024).to_bytes(4,'little') for i in range(1024))
k=b'\x10\0\0\0'+b''.join(i.to_bytes(4,'little',signed=True) for i in list(range(-256,0))+list(range(1,257)))
a=Packet(Kind.SOURCE,11,NO_FRAME,source).encode()
b=Packet(Kind.K_WEIGHTS,12,NO_FRAME,k).encode()
r=Packet(Kind.RUN_CONTROL,15,NO_FRAME,(1).to_bytes(4,'little')).encode()
bad=bytearray(a);bad[-1]^=1
invalid_headers=[]
for offset,value in [(4,2),(5,0x22),(6,0x80),(8,0xff),(20,1)]:
    head=bytearray(a[:36]);head[offset]=value;invalid_headers.append(bytes(head))
bad_semantics=[]
for packet,offset,value in [(a,0,0),(a,0,0x40000001),(b,0,0x00010010),(b,4,1)]:
    body=bytearray(packet[:-4]);body[36+offset:40+offset]=value.to_bytes(4,'little')
    bad_semantics.append(bytes(body)+zlib.crc32(body).to_bytes(4,'little'))
body=bytearray(r[:-4]);body[36:40]=(2).to_bytes(4,'little')
bad_semantics.append(bytes(body)+zlib.crc32(body).to_bytes(4,'little'))
prefix=b'noiseSP'+b''.join(invalid_headers)+bytes(bad)+b''.join(bad_semantics)
stream=prefix+a+b+r
source2=b''.join((2+i*1024).to_bytes(4,'little') for i in range(1024))
k2=(17).to_bytes(2,'little')+bytes(2)+b''.join((-i).to_bytes(4,'little',signed=True) for i in list(range(-256,0))+list(range(1,257)))
loader_stream=prefix+a+b+Packet(Kind.SOURCE,13,NO_FRAME,source2).encode()+Packet(Kind.K_WEIGHTS,14,NO_FRAME,k2).encode()
for name,data in [('rx_input.hex',stream),('rx_expected.hex',source+k+r[36:40]),('rx_good.hex',a),('loader_input.hex',loader_stream)]:
    (out/name).write_text(''.join(f'{v:02x}\n' for v in data))
(out/'rx_sizes.vh').write_text(f'localparam INPUT_SIZE={len(stream)},LOADER_INPUT_SIZE={len(loader_stream)},OUTPUT_SIZE={len(source+k)+4},GOOD_SIZE={len(a)},EXPECTED_ERRORS={len(invalid_headers)+1+len(bad_semantics)};\n')
