import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from host.protocol import Packet,Kind,Decoder,TIME_VALID,DISCONTINUITY
actual=bytes.fromhex(Path(sys.argv[1]).read_text())
expected=b''
for i in range(2):
    payload=b''.join(((n*73+19)%4096).to_bytes(2,'little') for n in range(i*1024,(i+1)*1024))
    expected+=Packet(Kind.RAW,i,123+2*i,payload,timestamp=999 if i==0 else 0,
                     flags=TIME_VALID if i==0 else DISCONTINUITY).encode()
assert actual==expected, 'RAW bytes/metadata/CRC mismatch'
decoder=Decoder();packets=[]
for i in range(0,len(actual),37): packets.extend(decoder.feed(actual[i:i+37]))
assert len(packets)==2
print('PASS: RAW packets match host codec including metadata, CRC and fragmented decode')
