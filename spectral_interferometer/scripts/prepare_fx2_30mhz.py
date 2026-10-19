"""Generate a RAM-download HEX candidate; never accesses USB or EEPROM."""
import argparse
import hashlib
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'sim'))
from audit_fx2_firmware import read_hex, read_iic

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('original_folder', type=Path)
p.add_argument('output_hex', type=Path)
a = p.parse_args()
iic = a.original_folder / 'slave.iic'
expected = 'e3c2c8c3cb9f1d4b52f205acec3df010ccd88bb4d47e57af9055cd4f836870f4'
if hashlib.sha256(iic.read_bytes()).hexdigest() != expected:
    raise SystemExit('Unrecognized original firmware; refusing patch')
original = read_hex(a.original_folder / 'slave.hex')
boot = read_iic(iic)
if any(boot.get(k) != v for k, v in original.items()):
    raise SystemExit('HEX and IIC disagree')
if bytes(original.get(0x08DA+i, 0) for i in range(6)) != bytes.fromhex('90 E6 01 74 E3 F0'):
    raise SystemExit('IFCONFIG instruction mismatch')
candidate = dict(original)
candidate[0x08DE] = 0xA3
lines = []
addresses = sorted(candidate)
while addresses:
    start = addresses[0]
    chunk = []
    while addresses and len(chunk) < 16 and addresses[0] == start+len(chunk):
        chunk.append(candidate[addresses.pop(0)])
    record = bytes([len(chunk), start >> 8, start & 255, 0] + chunk)
    lines.append(':' + (record+bytes([-sum(record) & 255])).hex().upper())
lines.append(':00000001FF')
with a.output_hex.open('x', encoding='ascii') as f:
    f.write('\n'.join(lines)+'\n')
decoded = read_hex(a.output_hex)
assert decoded == candidate
assert [k for k in original if original[k] != decoded[k]] == [0x08DE]
print('VERIFIED: sole payload change 0x08DE E3->A3; original files untouched')
print('CANDIDATE ONLY: pair with 30 MHz FPGA build; no hardware download performed')
print('SHA256', hashlib.sha256(a.output_hex.read_bytes()).hexdigest())
