"""Hardware gate for stopped boot, graceful RUN control and S/K retention."""
import argparse
import json
from pathlib import Path
import struct
import time

import numpy as np

from protocol import (Decoder, Kind, export_command, k_command, run_command,
                      source_command)
from reference import Calibration, load_vector
from usb_transport import CypressUSB


MEASUREMENTS = {Kind.RAW, Kind.SPECTRUM, Kind.PHASE, Kind.RESULT}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--summary', type=Path, required=True)
    parser.add_argument('--k')
    parser.add_argument('--timeout', type=float, default=8.0)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.summary.parent.mkdir(parents=True, exist_ok=True)
    decoder = Decoder()
    packets = []
    events = []

    def read_once(usb, recording):
        transfer = usb.read()
        if transfer.data:
            recording.write(transfer.data)
            packets.extend(decoder.feed(transfer.data))
        if not transfer.success and not transfer.idle_timeout:
            raise IOError(f'USB read failed: error={transfer.error}, count={transfer.count}, '
                          f'NT={transfer.nt_status:08X}, USBD={transfer.usbd_status:08X}, '
                          f'elapsed_ms={transfer.elapsed_ms}')

    def wait_for(usb, recording, predicate, label):
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            read_once(usb, recording)
            result = predicate()
            if result is not None:
                return result
        raise TimeoutError(f'Timed out waiting for {label}')

    def send_and_ack(usb, recording, command, label):
        start = len(packets)
        encoded = command.encode()
        transfer = usb.write(encoded)
        if not transfer.success or transfer.count != len(encoded):
            raise IOError(f'Uncertain {label} write: {transfer.count}/{len(encoded)}')

        def find_ack():
            for packet in packets[start:]:
                if packet.kind == Kind.ACK:
                    sequence, status, reserved = struct.unpack('<IHH', packet.payload)
                    if sequence == command.sequence:
                        if status or reserved:
                            raise RuntimeError(f'{label} rejected: {status}/{reserved}')
                        return packet
            return None

        ack = wait_for(usb, recording, find_ack, f'{label} ACK')
        events.append(dict(label=label, sequence=command.sequence,
                           source_version=ack.source_version,
                           k_version=ack.k_version, packet_index=len(packets)))
        return ack

    def assert_quiet(usb, recording, seconds, label):
        start = len(packets)
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            read_once(usb, recording)
        unexpected = [p.kind.name for p in packets[start:] if p.kind in MEASUREMENTS]
        if unexpected:
            raise RuntimeError(f'{label}: measurement packets after STOP ACK: {unexpected[:8]}')

    sequence = 1000
    with args.output.open('xb') as recording, CypressUSB(args.dll) as usb:
        # Drain any bytes left in the FX2 endpoint by the previously running image.
        drain_deadline = time.monotonic() + 0.4
        while time.monotonic() < drain_deadline:
            read_once(usb, recording)

        send_and_ack(usb, recording, run_command(False, sequence), 'initial stop')
        sequence += 1
        assert_quiet(usb, recording, 0.45, 'stopped boot')
        send_and_ack(usb, recording, export_command(50, sequence), 'export interval')
        sequence += 1
        start_ack = send_and_ack(usb, recording, run_command(True, sequence), 'first start')
        sequence += 1
        scan = len(packets)
        raw = wait_for(usb, recording,
                       lambda: next((p for p in packets[scan:] if p.kind == Kind.RAW), None),
                       'RAW after first start')
        if not raw.flags & 4:
            raise RuntimeError('RAW lacks hardware timestamp')
        source = np.frombuffer(raw.payload, '<u2').copy()
        if np.any(source < 1):
            raise RuntimeError('Captured S contains zero; provide weak light and retry')
        send_and_ack(usb, recording, run_command(False, sequence), 'first stop')
        sequence += 1
        assert_quiet(usb, recording, 0.45, 'first stop')

        k = load_vector(args.k) if args.k else np.arange(1024, dtype=np.float64)
        calibration = Calibration.create(source, k)
        source_ack = send_and_ack(usb, recording, source_command(source, sequence), 'source')
        sequence += 1
        k_ack = send_and_ack(usb, recording, k_command(calibration, sequence), 'k weights')
        sequence += 1
        versions = (source_ack.source_version, k_ack.k_version)

        def run_and_result(label):
            nonlocal sequence
            send_and_ack(usb, recording, run_command(True, sequence), f'{label} start')
            sequence += 1
            scan_result = len(packets)
            result = wait_for(
                usb, recording,
                lambda: next((p for p in packets[scan_result:]
                              if p.kind == Kind.RESULT and
                              (p.source_version, p.k_version) == versions), None),
                f'{label} retained-version RESULT')
            send_and_ack(usb, recording, run_command(False, sequence), f'{label} stop')
            sequence += 1
            assert_quiet(usb, recording, 0.45, f'{label} stop')
            return result

        first_result = run_and_result('calibrated run 1')
        second_result = run_and_result('calibrated run 2')

    if decoder.bad_crc or decoder.bad_payloads or decoder.bad_headers:
        raise RuntimeError('SPIF decoder reported integrity errors')
    summary = dict(
        result='PASS', initial_start_ack_versions=[start_ack.source_version, start_ack.k_version],
        source=dict(minimum=int(source.min()), maximum=int(source.max()),
                    mean=float(source.mean()), std=float(source.std())),
        retained_versions=list(versions),
        result_frame_ids=[first_result.frame_id, second_result.frame_id],
        events=events, packets=decoder.packets,
        bad_headers=decoder.bad_headers, bad_crc=decoder.bad_crc,
        bad_payloads=decoder.bad_payloads,
        recording=str(args.output.resolve()),
        note='K defaults to a synthetic monotonic vector; this is a control-path gate, not optical calibration.')
    with args.summary.open('x', encoding='utf-8') as stream:
        json.dump(summary, stream, ensure_ascii=False, indent=2)
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
