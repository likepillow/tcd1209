"""One-session final acceptance: W/T, S/K, RESULT cadence and integrity."""
import argparse
import json
from pathlib import Path
import struct
import time

import numpy as np

from acquisition_settings import AcquisitionSettings
from protocol import (Decoder, DistanceResult, Kind, TIME_VALID,
                      acquisition_command, export_command, k_command, source_command)
from reference import Calibration, load_vector
from usb_transport import CypressUSB


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', required=True)
    parser.add_argument('--k', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--summary', type=Path, required=True)
    parser.add_argument('--results', type=int, default=500)
    parser.add_argument('--timeout', type=float, default=8.0)
    args = parser.parse_args()
    decoder, packets = Decoder(), []
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def read(usb, recording):
        transfer = usb.read()
        if transfer.data:
            recording.write(transfer.data)
            packets.extend(decoder.feed(transfer.data))
        if not transfer.success and not transfer.idle_timeout:
            raise IOError(f'USB read failed: {transfer.error}/{transfer.count}')

    def wait(usb, recording, predicate, label):
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            read(usb, recording)
            value = predicate()
            if value is not None:
                return value
        raise TimeoutError(f'Timed out waiting for {label}')

    def send_and_ack(usb, recording, command):
        start = len(packets)
        encoded = command.encode()
        transfer = usb.write(encoded)
        if not transfer.success or transfer.count != len(encoded):
            raise IOError(f'Command write uncertain: {transfer.count}/{len(encoded)}')

        def ack():
            for packet in reversed(packets[start:]):
                if packet.kind == Kind.ACK:
                    sequence, status, reserved = struct.unpack('<IHH', packet.payload)
                    if sequence == command.sequence:
                        if status or reserved:
                            raise RuntimeError(f'Command rejected: {status}/{reserved}')
                        return packet
            return None
        return wait(usb, recording, ack, f'ACK {command.sequence}')

    settings = AcquisitionSettings(512, 2114)
    with args.output.open('xb') as recording, CypressUSB(args.dll) as usb:
        send_and_ack(usb, recording, acquisition_command(settings, 300))
        raw = wait(usb, recording,
                   lambda: next((p for p in reversed(packets) if p.kind == Kind.RAW), None),
                   'post-W/T RAW')
        source = np.frombuffer(raw.payload, '<u2').copy()
        calibration = Calibration.create(source, load_vector(args.k))
        source_ack = send_and_ack(usb, recording, source_command(source, 301))
        k_ack = send_and_ack(usb, recording, k_command(calibration, 302))
        export_ack = send_and_ack(usb, recording, export_command(0, 303))

        # Ignore results already decoded in the same transfer as an ACK. Begin
        # with a fresh list while retaining the one continuous USB ownership.
        collected = []
        started = time.monotonic()
        deadline = started + args.timeout
        scan = len(packets)
        while len(collected) < args.results and time.monotonic() < deadline:
            read(usb, recording)
            for packet in packets[scan:]:
                if packet.kind == Kind.RESULT:
                    collected.append((packet, DistanceResult.from_packet(packet)))
            scan = len(packets)
        elapsed = time.monotonic() - started
    if len(collected) < args.results:
        raise TimeoutError(f'Only received {len(collected)} RESULT packets')
    collected = collected[:args.results]
    result_packets = [item[0] for item in collected]
    results = [item[1] for item in collected]
    frame_steps = [(b.frame_id-a.frame_id) & 0xffffffff
                   for a, b in zip(result_packets, result_packets[1:])]
    tick_steps = [b.timestamp-a.timestamp for a, b in zip(result_packets, result_packets[1:])]
    expected = settings.period_pixels * 20
    if any(not packet.flags & TIME_VALID for packet in result_packets):
        raise RuntimeError('RESULT lacks TIME_VALID')
    if any(step != 1 or ticks != expected for step, ticks in zip(frame_steps, tick_steps)):
        raise RuntimeError('RESULT frames are not contiguous at the configured period')
    if any(result.dropped_frames or result.malformed_frames for result in results):
        raise RuntimeError('Loss counters are nonzero in fresh one-session acceptance')
    wall_rate = len(collected) / elapsed
    if wall_rate <= 1000:
        raise RuntimeError(f'Host RESULT throughput too low: {wall_rate}')
    if decoder.bad_crc or decoder.bad_payloads:
        raise RuntimeError('SPIF integrity failure')
    summary = dict(result='PASS', settings=dict(window_start=settings.window_start,
                                                exposure_us=float(settings.exposure_us),
                                                nominal_hz=settings.nominal_hz),
                   source=dict(minimum=int(source.min()), maximum=int(source.max()),
                               mean=float(source.mean()), std=float(source.std())),
                   acknowledgements=dict(acquisition=[300, 0], source=[301, source_ack.source_version],
                                         k=[302, k_ack.k_version], export=[303, 0]),
                   result_packets=len(collected), elapsed_seconds=elapsed,
                   host_observed_result_hz=wall_rate,
                   timestamp_tick_step=expected,
                   first_frame_id=result_packets[0].frame_id,
                   last_frame_id=result_packets[-1].frame_id,
                   invalid_results=sum(result.invalid for result in results),
                   dropped_frames=results[-1].dropped_frames,
                   malformed_frames=results[-1].malformed_frames,
                   bad_headers=decoder.bad_headers, bad_crc=decoder.bad_crc,
                   bad_payloads=decoder.bad_payloads,
                   recording=str(args.output.resolve()),
                   note='Temporary captured S and simulation K; not a physical distance calibration.')
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    with args.summary.open('x', encoding='utf-8') as stream:
        json.dump(summary, stream, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    main()
