"""Create a one-byte IFCONFIG patch only after auditing the physical EEPROM backup."""
from pathlib import Path
import argparse, hashlib, sys, json
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'sim'))
from audit_fx2_firmware import read_iic, read_hex
p=argparse.ArgumentParser()
p.add_argument('original_folder',type=Path)
a=p.parse_args()
root=Path(__file__).resolve().parents[1]
original=a.original_folder/'slave.iic'
data=bytearray(original.read_bytes())
if hashlib.sha256(data).hexdigest()!='e3c2c8c3cb9f1d4b52f205acec3df010ccd88bb4d47e57af9055cd4f836870f4':
    raise SystemExit('Original firmware hash mismatch')
backup=(root/'build/flash_audit/original_fx2_eeprom.bin').read_bytes()
if len(backup)!=8192 or backup[:len(data)]!=data:
    raise SystemExit('Physical EEPROM differs from original image; stop before programming')
position=8
patched=[]
while position+4<=len(data):
    length=int.from_bytes(data[position:position+2],'big')
    address=int.from_bytes(data[position+2:position+4],'big')
    count=length&0x7fff
    position+=4
    if address<=0x08de<address+count:
        offset=position+0x08de-address
        if data[offset]!=0xe3: raise SystemExit('IFCONFIG is not E3')
        data[offset]=0xa3
        patched.append(offset)
    position+=count
    if length&0x8000: break
if len(patched)!=1 or position!=len(data): raise SystemExit('Unexpected IIC records')
output=root/'build/flash_audit/slave_30mhz.iic'
with output.open('xb') as f: f.write(data)
candidate=read_iic(output)
ram=read_hex(root/'build/slave_30mhz_candidate.hex')
if any(candidate.get(k)!=v for k,v in ram.items()): raise SystemExit('RAM/EEPROM images differ')
print(json.dumps(dict(bytes=len(data),changed_eeprom_offsets=patched,
    sha256=hashlib.sha256(data).hexdigest(),backup_sha256=hashlib.sha256(backup).hexdigest(),
    unchanged_tail_bytes=len(backup)-len(data)),indent=2))
