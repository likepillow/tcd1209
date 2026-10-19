"""Bounded read-only SPIF capture from an already-running board30 design."""
import argparse
import json
from pathlib import Path
import time

import numpy as np

from protocol import Decoder, Kind, SequenceTracker, TIME_VALID
from usb_transport import CypressUSB


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--seconds', type=float, default=3.0)
    parser.add_argument('--minimum-raw', type=int, default=2)
    parser.add_argument('--require-timestamps', action='store_true',
                        help='require every RAW frame to carry a monotonic FPGA timestamp')
    parser.add_argument('--summary', type=Path, help='write JSON evidence only after passing checks')
    args = parser.parse_args()
    if not 0.5 <= args.seconds <= 30:
        raise ValueError('seconds must be 0.5..30')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    decoder, sequence = Decoder(), SequenceTracker()
    raw_stats, raw_timestamps, kinds = [], [], {}
    started = time.monotonic()
    with args.output.open('xb') as recording, CypressUSB(args.dll) as usb:
        while time.monotonic() - started < args.seconds:
            transfer = usb.read()
            if transfer.data:
                recording.write(transfer.data)
                for packet in decoder.feed(transfer.data):
                    sequence.observe(packet.sequence)
                    kinds[packet.kind.name] = kinds.get(packet.kind.name, 0) + 1
                    if packet.kind == Kind.RAW:
                        values = np.frombuffer(packet.payload, '<u2')
                        time_valid = bool(packet.flags & TIME_VALID)
                        if time_valid:
                            raw_timestamps.append(packet.timestamp)
                        raw_stats.append(dict(frame_id=packet.frame_id,
                                              timestamp=packet.timestamp,
                                              time_valid=time_valid,
                                              minimum=int(values.min()),
                                              maximum=int(values.max()),
                                              mean=float(values.mean()),
                                              standard_deviation=float(values.std())))
            if not transfer.success and not transfer.idle_timeout:
                raise IOError(f'USB read failed: error={transfer.error}, bytes={transfer.count}, '
                              f'NT={transfer.nt_status:08x}, USBD={transfer.usbd_status:08x}')
    timestamp_deltas = [b-a for a, b in zip(raw_timestamps, raw_timestamps[1:])]
    summary = dict(elapsed_seconds=time.monotonic()-started, packets=decoder.packets,
                   kinds=kinds, raw_frames=len(raw_stats), raw=raw_stats[-8:],
                   timestamped_raw_frames=len(raw_timestamps),
                   timestamp_delta_ticks=timestamp_deltas[-8:],
                   missing_sequences=sequence.missing, out_of_order=sequence.out_of_order,
                   discarded_bytes=decoder.discarded_bytes, bad_headers=decoder.bad_headers,
                   bad_crc=decoder.bad_crc, bad_payloads=decoder.bad_payloads,
                   trailing_bytes=len(decoder.buffer), recording=str(args.output.resolve()))
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    if len(raw_stats) < args.minimum_raw:
        raise SystemExit(f'Expected at least {args.minimum_raw} RAW frames')
    if decoder.bad_crc or decoder.bad_payloads or sequence.out_of_order:
        raise SystemExit('SPIF integrity check failed')
    if args.require_timestamps:
        if len(raw_timestamps) != len(raw_stats):
            raise SystemExit('One or more RAW packets lack TIME_VALID')
        if any(delta <= 0 for delta in timestamp_deltas):
            raise SystemExit('RAW FPGA timestamps are not strictly monotonic')
    if args.summary:
        if sequence.missing or decoder.bad_headers or decoder.discarded_bytes:
            raise SystemExit('Strict evidence gate failed: missing/corrupt stream')
        with args.summary.open('x', encoding='utf-8') as stream:
            json.dump(summary, stream, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    main()
