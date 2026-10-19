import sys,struct
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from host.protocol import Packet,Kind,NO_FRAME,Decoder
actual=bytes.fromhex(Path(sys.argv[1]).read_text())
raw=b''.join(((i*73+19)%4096).to_bytes(2,'little') for i in range(1024))
result=(-123456789).to_bytes(12,'little',signed=True)+struct.pack('<hHHHII',24,97,95,99,0,0)
expected=(Packet(Kind.ACK,0,NO_FRAME,struct.pack('<IHH',44,0,0),source_version=1,k_version=1).encode()+
          Packet(Kind.RAW,1,55,raw,timestamp=777,flags=4).encode()+
          Packet(Kind.RESULT,2,55,result,timestamp=777,source_version=1,k_version=1,flags=4).encode())
assert actual==expected,'shared packet stream mismatch'
decoder=Decoder();packets=[]
for i in range(0,len(actual),31):packets.extend(decoder.feed(actual[i:i+31]))
assert [p.kind for p in packets]==[Kind.ACK,Kind.RAW,Kind.RESULT]
assert [p.sequence for p in packets]==[0,1,2]
print('PASS: shared real SPIF packets match host codec, common sequences and CRCs')
