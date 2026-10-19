"""Exercise live SOURCE/K commands, applied ACKs and FPGA RESULT packets."""
import argparse
import json
from pathlib import Path
import struct
import time

import numpy as np

from protocol import Decoder, DistanceResult, Kind, k_command, source_command
from reference import Calibration, load_vector
from usb_transport import CypressUSB


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', required=True)
    parser.add_argument('--k', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--timeout', type=float, default=8.0)
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    decoder = Decoder()
    raw_frames, results, acks = [], [], []

    def accept(data, recording):
        if data:
            recording.write(data)
        packets = list(decoder.feed(data))
        for packet in packets:
            if packet.kind == Kind.RAW:
                raw_frames.append(np.frombuffer(packet.payload, '<u2').copy())
            elif packet.kind == Kind.RESULT:
                value = DistanceResult.from_packet(packet)
                results.append(dict(frame_id=packet.frame_id, invalid=value.invalid,
                                    distance=None if value.invalid else value.distance,
                                    peak=value.peak, left=value.left, right=value.right,
                                    source_version=packet.source_version,
                                    k_version=packet.k_version,
                                    dropped=value.dropped_frames,
                                    malformed=value.malformed_frames))
            elif packet.kind == Kind.ACK:
                command_sequence, status, _ = struct.unpack('<IHH', packet.payload)
                acks.append(dict(command_sequence=command_sequence, status=status,
                                 source_version=packet.source_version,
                                 k_version=packet.k_version))
        return packets

    def read_once(usb, recording):
        transfer = usb.read()
        packets = accept(transfer.data, recording)
        if not transfer.success and not transfer.idle_timeout:
            raise IOError(f'USB read failed: error={transfer.error}, bytes={transfer.count}, '
                          f'NT={transfer.nt_status:08x}, USBD={transfer.usbd_status:08x}')
        return packets

    def wait_for(usb, recording, predicate, label):
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            read_once(usb, recording)
            value = predicate()
            if value is not None:
                return value
        raise TimeoutError(f'Timed out waiting for {label}')

    with args.output.open('xb') as recording, CypressUSB(args.dll) as usb:
        wait_for(usb, recording, lambda: raw_frames[-1] if raw_frames else None, 'first RAW frame')
        source = raw_frames[-1]
        k = load_vector(args.k)
        calibration = Calibration.create(source, k)
        commands = [source_command(source, 0), k_command(calibration, 1)]
        for command in commands:
            encoded = command.encode()
            transfer = usb.write(encoded)
            if not transfer.success or transfer.count != len(encoded):
                raise IOError(f'Command write uncertain: {transfer.count}/{len(encoded)}, error={transfer.error}')
            ack = wait_for(usb, recording,
                           lambda seq=command.sequence: next((a for a in reversed(acks)
                                                              if a['command_sequence'] == seq), None),
                           f'ACK {command.sequence}')
            if ack['status'] != 0:
                raise IOError(f'FPGA rejected command {command.sequence}: status={ack["status"]}')
        wait_for(usb, recording,
                 lambda: results if len(results) >= 3 else None, 'three RESULT packets')

    if acks[-2] != dict(command_sequence=0, status=0, source_version=1, k_version=0):
        raise RuntimeError(f'Unexpected SOURCE ACK: {acks[-2]}')
    if acks[-1] != dict(command_sequence=1, status=0, source_version=1, k_version=1):
        raise RuntimeError(f'Unexpected K ACK: {acks[-1]}')
    qualified = [r for r in results if r['source_version'] == 1 and r['k_version'] == 1]
    if len(qualified) < 3 or any(r['dropped'] or r['malformed'] for r in qualified):
        raise RuntimeError('Missing qualified clean RESULT packets')
    if decoder.bad_crc or decoder.bad_payloads:
        raise RuntimeError('SPIF integrity failure')
    summary = dict(raw_reference=dict(minimum=int(source.min()), maximum=int(source.max()),
                                      mean=float(source.mean()), std=float(source.std())),
                   acks=acks, results=qualified[:8], total_packets=decoder.packets,
                   raw_frames=len(raw_frames), result_packets=len(results),
                   bad_headers=decoder.bad_headers, bad_crc=decoder.bad_crc,
                   bad_payloads=decoder.bad_payloads,
                   recording=str(args.output.resolve()),
                   note='Temporary test S and simulation K; not a physical distance calibration')
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
