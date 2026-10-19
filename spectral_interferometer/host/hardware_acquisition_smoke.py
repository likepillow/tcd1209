"""Verify runtime W/T commands, ACKs and frame periods on connected hardware."""
import argparse
import json
from pathlib import Path
import struct
import time

import numpy as np

from acquisition_settings import AcquisitionSettings
from protocol import Decoder, Kind, TIME_VALID, acquisition_command
from usb_transport import CypressUSB


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--summary', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=8.0)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    decoder = Decoder()
    packets = []
    integrity_baseline = None

    def receive(usb, recording):
        transfer = usb.read()
        if transfer.data:
            recording.write(transfer.data)
            packets.extend(decoder.feed(transfer.data))
        if not transfer.success and not transfer.idle_timeout:
            raise IOError(f'USB read failed: error={transfer.error}, bytes={transfer.count}, '
                          f'NT={transfer.nt_status:08x}, USBD={transfer.usbd_status:08x}')

    def wait_for(usb, recording, predicate, label):
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            receive(usb, recording)
            value = predicate()
            if value is not None:
                return value
        raise TimeoutError(f'Timed out waiting for {label}')

    settings_to_test = [
        AcquisitionSettings(0, 2500),       # 500.0 us
        AcquisitionSettings(512, 2114),     # 422.8 us, fastest supported
        AcquisitionSettings(1024, 4999),    # 999.8 us, slowest supported
        AcquisitionSettings(512, 2114),     # restore power-up defaults
    ]
    evidence = []
    with args.output.open('xb') as recording, CypressUSB(args.dll) as usb:
        # Establish that the autonomous acquisition stream is alive first.
        wait_for(usb, recording,
                 lambda: next((p for p in reversed(packets) if p.kind == Kind.RAW), None),
                 'initial RAW frame')
        # Opening an already-running bulk stream may begin in the middle of one
        # packet. Only integrity changes after the first decoded packet matter.
        integrity_baseline = (decoder.bad_headers, decoder.bad_crc,
                              decoder.bad_payloads, decoder.discarded_bytes)
        for sequence, settings in enumerate(settings_to_test, 100):
            start_index = len(packets)
            command = acquisition_command(settings, sequence)
            encoded = command.encode()
            transfer = usb.write(encoded)
            if not transfer.success or transfer.count != len(encoded):
                raise IOError(f'Command write uncertain: {transfer.count}/{len(encoded)}, '
                              f'error={transfer.error}')

            def matching_ack():
                for packet in reversed(packets[start_index:]):
                    if packet.kind == Kind.ACK:
                        command_sequence, status, reserved = struct.unpack('<IHH', packet.payload)
                        if command_sequence == sequence:
                            return packet, status, reserved
                return None

            ack, status, reserved = wait_for(usb, recording, matching_ack, f'ACK {sequence}')
            if status or reserved:
                raise RuntimeError(f'Command {sequence} rejected: status={status}, reserved={reserved}')
            ack_index = packets.index(ack, start_index)

            def twelve_raw():
                values = [p for p in packets[ack_index + 1:] if p.kind == Kind.RAW]
                return values if len(values) >= 12 else None

            raw = wait_for(usb, recording, twelve_raw, f'RAW frames after ACK {sequence}')[:12]
            if any(not p.flags & TIME_VALID for p in raw):
                raise RuntimeError('RAW frame lacks TIME_VALID')
            deltas = [b.timestamp - a.timestamp for a, b in zip(raw, raw[1:])]
            frame_steps = [(b.frame_id - a.frame_id) & 0xffffffff
                           for a, b in zip(raw, raw[1:])]
            expected_ticks = settings.period_pixels * 20  # 5 MHz pixel clock, 100 MHz timestamp
            if any(step == 0 or delta != expected_ticks * step
                   for delta, step in zip(deltas, frame_steps)):
                raise RuntimeError(f'Wrong frame period for {settings}: {deltas}')
            samples = np.concatenate([np.frombuffer(p.payload, '<u2') for p in raw])
            evidence.append(dict(sequence=sequence, window_start=settings.window_start,
                                 exposure_us=float(settings.exposure_us),
                                 nominal_hz=settings.nominal_hz,
                                 expected_timestamp_ticks=expected_ticks,
                                 observed_timestamp_ticks=sorted(set(deltas)),
                                 observed_frame_steps=sorted(set(frame_steps)),
                                 frame_ids=[p.frame_id for p in raw],
                                 adc_min=int(samples.min()), adc_max=int(samples.max()),
                                 adc_mean=float(samples.mean()), adc_std=float(samples.std()),
                                 source_version=ack.source_version, k_version=ack.k_version))

    integrity_final = (decoder.bad_headers, decoder.bad_crc,
                       decoder.bad_payloads, decoder.discarded_bytes)
    if integrity_final != integrity_baseline:
        raise RuntimeError('SPIF integrity failure')
    summary = dict(result='PASS', configurations=evidence,
                   packets=decoder.packets, bad_headers=decoder.bad_headers,
                   bad_crc=decoder.bad_crc, bad_payloads=decoder.bad_payloads,
                   discarded_bytes=decoder.discarded_bytes,
                   recording=str(args.output.resolve()),
                   note='W endpoint behavior is additionally covered by deterministic RTL simulation.')
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    with args.summary.open('x', encoding='utf-8') as stream:
        json.dump(summary, stream, ensure_ascii=False, indent=2)


if __name__ == '__main__':
    main()
