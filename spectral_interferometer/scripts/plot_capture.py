"""Export the last complete RAW frame of a SPIF recording for handover."""
import argparse
from pathlib import Path
import sys
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'host'))
from protocol import Decoder, Kind

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('recording', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
decoder = Decoder()
last = None
with args.recording.open('rb') as stream:
    while chunk := stream.read(65536):
        for packet in decoder.feed(chunk):
            if packet.kind == Kind.RAW:
                last = packet
if last is None:
    raise SystemExit('No complete RAW frame')
values = np.frombuffer(last.payload, '<u2')
args.output.parent.mkdir(parents=True, exist_ok=True)
np.savetxt(args.output.with_suffix('.txt'), values, fmt='%d')
low, high = int(values.min())-10, int(values.max())+10
points = ' '.join(f'{70+i*900/1023:.2f},{300-(int(v)-low)*240/(high-low):.2f}' for i,v in enumerate(values))
svg = ['<svg xmlns="http://www.w3.org/2000/svg" width="1000" height="360" viewBox="0 0 1000 360">',
       '<rect width="1000" height="360" fill="white"/>',
       f'<text x="70" y="25" font-family="sans-serif" font-size="17">CCD S0, frame {last.frame_id}; mean {values.mean():.2f}, range {values.min()}–{values.max()}</text>']
for tick in range(5):
    y=300-tick*60
    svg.append(f'<path d="M70 {y} H970" stroke="#dde3ea"/><text x="20" y="{y+5}" font-family="sans-serif">{low+(high-low)*tick/4:.1f}</text>')
svg += [f'<polyline points="{points}" fill="none" stroke="#1676a8" stroke-width="1"/>',
        '<text x="70" y="322">512</text><text x="940" y="322">1535</text>',
        '<text x="340" y="348" font-family="sans-serif">Effective pixel index (zero based); amplitude in ADC counts</text></svg>']
args.output.write_text('\n'.join(svg), encoding='utf-8')
print(args.output.resolve())
