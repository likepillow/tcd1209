"""Compare runtime Flash readback and prove unrelated sectors were preserved."""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1]
old = (root/'build/flash_audit/programmed_flash.bin').read_bytes()
actual = (root/'build/runtime_flash_audit/programmed_flash.bin').read_bytes()
image = (root/'build/runtime_deploy/instrument_runtime.bin').read_bytes()
assert len(old) == len(actual) == 16777216, 'Missing full readback'
assert 0 < len(image) <= len(old), 'Bad image length'
assert actual[:len(image)] == image, 'Runtime image contents mismatch'
erase_end = (len(image)+65535)//65536*65536
assert actual[erase_end:] == old[erase_end:], 'Unaddressed Flash content changed'
assert all(a == 255 or a == b for a, b in zip(actual[len(image):erase_end],
                                               old[len(image):erase_end])), 'Unexpected erase padding'
result = dict(status='PASS', image_bytes=len(image), erase_bound=erase_end,
              untouched_bytes=len(old)-erase_end,
              image_sha256=hashlib.sha256(image).hexdigest(),
              readback_sha256=hashlib.sha256(actual).hexdigest(),
              previous_sha256=hashlib.sha256(old).hexdigest())
with (root/'build/runtime_flash_audit/flash_verify.json').open('x', encoding='utf-8') as stream:
    json.dump(result, stream, indent=2)
print(json.dumps(result, indent=2))
