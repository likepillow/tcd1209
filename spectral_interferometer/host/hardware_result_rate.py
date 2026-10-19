"""Measure the configured FPGA RESULT cadence without changing calibration."""
import argparse
import json
from pathlib import Path
import struct
import time

from protocol import Decoder, DistanceResult, Kind, TIME_VALID, export_command
from usb_transport import CypressUSB


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--summary', type=Path, required=True)
    parser.add_argument('--results', type=int, default=100)
    parser.add_argument('--timeout', type=float, default=5.0)
    args = parser.parse_args()
    decoder, found, counters = Decoder(), [], []
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open('xb') as recording, CypressUSB(args.dll) as usb:
        # Remove RAW traffic so this measures the RESULT channel itself.
        command_sequence = 0x525445
        encoded = export_command(0, command_sequence).encode()
        transfer = usb.write(encoded)
        if not transfer.success or transfer.count != len(encoded):
            raise IOError('Could not disable RAW export')
        deadline = time.monotonic() + args.timeout
        acknowledged = False
        while not acknowledged and time.monotonic() < deadline:
            transfer = usb.read()
            if transfer.data:
                recording.write(transfer.data)
                for packet in decoder.feed(transfer.data):
                    if packet.kind == Kind.ACK:
                        sequence, status, reserved = struct.unpack('<IHH', packet.payload)
                        if sequence == command_sequence:
                            if status or reserved:
                                raise RuntimeError(f'EXPORT command rejected: {status}/{reserved}')
                            acknowledged = True
            if not transfer.success and not transfer.idle_timeout:
                raise IOError(f'USB read failed: error={transfer.error}, bytes={transfer.count}')
        if not acknowledged:
            raise TimeoutError('Timed out waiting for EXPORT ACK')
        found.clear()
        counters.clear()
        started = time.monotonic()
        while len(found) < args.results and time.monotonic() - started < args.timeout:
            transfer = usb.read()
            if transfer.data:
                recording.write(transfer.data)
                for packet in decoder.feed(transfer.data):
                    if packet.kind == Kind.RESULT:
                        result = DistanceResult.from_packet(packet)
                        if not packet.flags & TIME_VALID:
                            raise RuntimeError('RESULT lacks TIME_VALID')
                        found.append(packet)
                        counters.append((result.dropped_frames, result.malformed_frames))
            if not transfer.success and not transfer.idle_timeout:
                raise IOError(f'USB read failed: error={transfer.error}, bytes={transfer.count}')
    if len(found) < args.results:
        raise TimeoutError(f'Only received {len(found)} RESULT packets')
    elapsed = time.monotonic() - started
    frame_steps = [(b.frame_id-a.frame_id) & 0xffffffff for a, b in zip(found, found[1:])]
    tick_steps = [b.timestamp-a.timestamp for a, b in zip(found, found[1:])]
    rates = [100_000_000.0*frame_step/tick_step
             for frame_step, tick_step in zip(frame_steps, tick_steps)]
    if any(step == 0 or tick <= 0 for step, tick in zip(frame_steps, tick_steps)):
        raise RuntimeError('Non-monotonic RESULT stream')
    minimum_rate = min(rates)
    if minimum_rate <= 1000.0:
        raise RuntimeError(f'RESULT rate is not above 1000 Hz: {minimum_rate}')
    wall_rate = len(found) / elapsed
    if wall_rate <= 1000.0:
        raise RuntimeError(f'Host-observed RESULT throughput is not above 1000 Hz: {wall_rate}')
    summary = dict(result='PASS', result_packets=len(found),
                   elapsed_seconds=elapsed, host_observed_result_hz=wall_rate,
                   first_frame_id=found[0].frame_id, last_frame_id=found[-1].frame_id,
                   timestamp_tick_steps=sorted(set(tick_steps)),
                   frame_steps=sorted(set(frame_steps)),
                   minimum_result_hz=minimum_rate, maximum_result_hz=max(rates),
                   source_version=found[-1].source_version,
                   k_version=found[-1].k_version,
                   cumulative_dropped_frames=counters[-1][0],
                   cumulative_malformed_frames=counters[-1][1],
                   loss_counter_start=list(counters[0]),
                   loss_counter_note='Diagnostic counters are cumulative and do not define packet cadence.',
                   bad_headers=decoder.bad_headers, bad_crc=decoder.bad_crc,
                   bad_payloads=decoder.bad_payloads,
                   recording=str(args.output.resolve()))
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    with args.summary.open('x', encoding='utf-8') as stream:
        json.dump(summary, stream, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    main()
