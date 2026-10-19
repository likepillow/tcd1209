"""Exact rational oracle for the standalone FPGA three-power peak fit."""
import argparse
from pathlib import Path
import random


def fit(peak, left, center, right):
    if peak <= 1 or peak >= 511 or center == 0 or max(left, right) > center:
        return 0, 1
    denominator = 2*(2*center-left-right)
    if denominator == 0:
        return 0, 1
    numerator = right-left
    value, remainder = divmod(abs(numerator)*2**20, denominator)
    if 2*remainder > denominator or (2*remainder == denominator and value & 1):
        value += 1
    return (-1 if numerator < 0 else 1)*min(value, 2**19), 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    rng = random.Random(1209)
    maximum = 2**65-1
    cases = [(43, 30, 100, 30), (72, 10, 100, 80), (72, 80, 100, 10),
             (10, 0, 100, 100), (10, 100, 100, 0), (1, 0, 100, 20),
             (511, 20, 100, 0), (0, 0, 0, 0), (50, 100, 100, 100),
             (50, 101, 100, 0), (50, 0, 100, 101),
             (10, maximum-1, maximum, maximum-2), (10, maximum, maximum, 0)]
    for _ in range(300):
        center = rng.randrange(1, 2**rng.randrange(1, 66))
        cases.append((rng.randrange(2, 511), rng.randrange(center+1), center, rng.randrange(center+1)))
    args.output.mkdir(parents=True, exist_ok=True)
    with (args.output/'coarse_vectors.mem').open('w') as stream:
        for peak, left, center, right in cases:
            delta, invalid = fit(peak, left, center, right)
            stream.write(f'{peak:03x} {left:017x} {center:017x} {right:017x} {delta & ((1<<21)-1):06x} {invalid:x}\n')
    print(f'{len(cases)} exact peak fit vectors')


if __name__ == '__main__':
    main()
