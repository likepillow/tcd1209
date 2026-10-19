"""RAW-only diagnostic at minimum T; restore this data set's W/T/S/K and STOP.

Not a distance acceptance test: the reference belongs to T=600 us, not the
shorter diagnostic exposure. Never program FPGA configuration or Flash.
"""
import argparse
import json
from pathlib import Path
import struct
import time

import numpy as np

from acquisition_settings import AcquisitionSettings
from protocol import (Decoder, Kind, SequenceTracker, acquisition_command,
                      export_command, run_command, source_command, k_command)
from reference import Calibration, load_vector
from usb_transport import CypressUSB


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', required=True)
    parser.add_argument('--source', required=True)
    parser.add_argument('--k', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    source, k = load_vector(args.source), load_vector(args.k)
    if len(source) != 1024 or len(k) != 1024:
        raise ValueError('This diagnostic requires the confirmed W=40 1024-point S/K')
    calibration = Calibration.create(source, k[256:768], distance_scale=.5, window_start=40)
    args.output.mkdir(parents=True, exist_ok=False)
    decoder, tracker, packets = Decoder(), SequenceTracker(), []
    sequence = 70000
    report = {'stop_confirmed': False, 'configuration_restored': False,
              'diagnostic_only': True, 'W': 40, 'probe_T_us': 422.8, 'restore_T_us': 600}
    with (args.output/'stream.spif').open('xb') as recording, CypressUSB(args.dll) as usb:
        def read():
            transfer = usb.read()
            if transfer.data:
                recording.write(transfer.data)
                for packet in decoder.feed(transfer.data):
                    tracker.observe(packet.sequence)
                    packets.append(packet)
            if not transfer.success and not transfer.idle_timeout:
                raise IOError('USB receive failed')

        def command(builder):
            nonlocal sequence
            packet = builder(sequence)
            sequence += 1
            wire = packet.encode()
            start = len(packets)
            transfer = usb.write(wire)
            if not transfer.success or transfer.count != len(wire):
                raise IOError('USB command write uncertain')
            deadline = time.monotonic()+8
            while time.monotonic() < deadline:
                read()
                for reply in packets[start:]:
                    if reply.kind == Kind.ACK:
                        number, status, reserved = struct.unpack('<IHH', reply.payload)
                        if number == packet.sequence:
                            if status or reserved:
                                raise RuntimeError(f'ACK rejected: {status}/{reserved}')
                            return reply
            raise TimeoutError('FPGA command ACK timeout')

        try:
            command(lambda seq: run_command(False, seq))
            command(lambda seq: acquisition_command(AcquisitionSettings(40, 2114), seq))
            command(lambda seq: export_command(1, seq))
            command(lambda seq: run_command(True, seq))
            start = len(packets)
            deadline = time.monotonic()+3
            frames = []
            while len(frames) < 32 and time.monotonic() < deadline:
                read()
                frames = [p for p in packets[start:] if p.kind == Kind.RAW]
            if len(frames) < 32:
                raise RuntimeError('Fewer than 32 RAW frames')
            raw = np.asarray([np.frombuffer(p.payload, '<u2') for p in frames])
            report.update(raw_frames=len(frames), adc_min=int(raw.min()), adc_max=int(raw.max()),
                          adc_mean=float(raw.mean()),
                          rail_frames=sum(int(np.any((r==0)|(r==4095))) for r in raw),
                          all_4095=bool(np.all(raw==4095)), all_zero=bool(np.all(raw==0)))
        except Exception as error:
            report['error'] = str(error)
        finally:
            try:
                command(lambda seq: run_command(False, seq))
                report['stop_confirmed'] = True
                command(lambda seq: acquisition_command(AcquisitionSettings(40, 3000), seq))
                command(lambda seq: source_command(source, seq))
                ack = command(lambda seq: k_command(calibration, seq))
                command(lambda seq: export_command(100, seq))
                report.update(configuration_restored=True, source_version=ack.source_version,
                              k_version=ack.k_version)
            except Exception as error:
                report['restore_error'] = str(error)
        report.update(bad_crc=decoder.bad_crc, bad_headers=decoder.bad_headers,
                      bad_payloads=decoder.bad_payloads, missing_packets=tracker.missing,
                      out_of_order_packets=tracker.out_of_order)
        (args.output/'summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if 'error' in report or not report['stop_confirmed'] or not report['configuration_restored']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
