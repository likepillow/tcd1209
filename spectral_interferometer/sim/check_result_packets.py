import sys,struct
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from host.protocol import Packet,Kind,Decoder
actual=bytes.fromhex(Path(sys.argv[1]).read_text())
expected=b''
for i,value in enumerate([(1<<82)+123,-(1<<83),0]):
    payload=value.to_bytes(12,'little',signed=True)+struct.pack('<hHHHII',-3 if i==1 else 32,97,95,99,3,4)
    expected+=Packet(Kind.RESULT,i,9+i,payload,timestamp=0x123456789abcdef0,
                     source_version=0x12345678,k_version=0xabcdef01,flags=7 if i==2 else 6).encode()
assert actual==expected,'RESULT bytes/metadata/sign extension/CRC mismatch'
decoder=Decoder();packets=[]
for i in range(0,len(actual),7): packets.extend(decoder.feed(actual[i:i+7]))
assert len(packets)==3
print('PASS: RESULT signed 84-bit extremes and metadata match host codec and fragmented decode')
