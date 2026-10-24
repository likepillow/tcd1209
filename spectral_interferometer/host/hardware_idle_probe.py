"""Read-only diagnostics for a stopped FX2 endpoint; no commands/reset/download."""
import argparse
from dataclasses import asdict
import json
from pathlib import Path

from usb_transport import CypressUSB

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--dll', required=True)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--count', type=int, default=30)
args = parser.parse_args()
rows = []
with CypressUSB(args.dll) as usb:
    for _ in range(args.count):
        transfer = usb.read()
        row = asdict(transfer)
        row['data'] = transfer.data.hex()
        row['classified_idle'] = transfer.idle_timeout
        rows.append(row)
with args.output.open('x', encoding='utf-8') as stream:
    json.dump(rows, stream, indent=2)
print(json.dumps(rows, indent=2))
