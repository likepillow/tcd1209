"""Compare full Flash readback to the image and ensure untouched sectors are preserved."""
from pathlib import Path
import hashlib,json
root=Path(__file__).resolve().parents[1]
audit=root/'build/flash_audit'
old=(audit/'original_flash.bin').read_bytes()
actual=(audit/'programmed_flash.bin').read_bytes()
image=(root/'build/standalone_deploy/instrument_standalone.bin').read_bytes()
assert len(old)==len(actual)==16777216, 'Missing full readback'
assert 0<len(image)<=len(old), 'Bad image length'
assert actual[:len(image)]==image, 'Image contents mismatch'
# MX25L12845G sector size is 4 KiB; use 64 KiB erase-block bound conservatively.
erase_end=(len(image)+65535)//65536*65536
assert actual[erase_end:]==old[erase_end:], 'Unaddressed flash content changed'
assert all(a==255 or a==b for a,b in zip(actual[len(image):erase_end],old[len(image):erase_end])), 'Unexpected erase-block padding'
result=dict(status='PASS',image_bytes=len(image),erase_bound=erase_end,
    untouched_bytes=len(old)-erase_end,
    image_sha256=hashlib.sha256(image).hexdigest(),
    readback_sha256=hashlib.sha256(actual).hexdigest(),
    backup_sha256=hashlib.sha256(old).hexdigest())
with (audit/'flash_verify.json').open('x',encoding='utf-8') as f: json.dump(result,f,indent=2)
print(json.dumps(result,indent=2))
