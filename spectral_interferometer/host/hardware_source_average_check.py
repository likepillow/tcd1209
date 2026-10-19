"""Check RAW capture cadence and reference averaging; always request STOP on exit.

Does not upload S/K or program the FPGA/Flash. The captured light is diagnostic,
not automatically certified as an interference-free source reference.
"""
import argparse
import json
from pathlib import Path
import struct
import time

import numpy as np

from protocol import Decoder, Kind, TIME_VALID, run_command, export_command
from usb_transport import CypressUSB
from workbench import DisplayState


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    decoder, display = Decoder(), DisplayState()
    packets, frames, ids, ticks = [], [], [], []
    sequence = 50000
    report = {'stop_confirmed': False, 'reference_qualified': False}
    with (args.output/'stream.spif').open('xb') as recording, CypressUSB(args.dll) as usb:
        def read():
            transfer = usb.read()
            if transfer.data:
                recording.write(transfer.data)
                for packet in decoder.feed(transfer.data):
                    packets.append(packet)
                    display.ingest(packet)
                    if packet.kind == Kind.RAW:
                        frames.append(np.frombuffer(packet.payload, '<u2').copy())
                        ids.append(packet.frame_id)
                        ticks.append(packet.timestamp if packet.flags & TIME_VALID else None)
            if not transfer.success and not transfer.idle_timeout:
                raise IOError(f'USB read failed: {transfer.error}/{transfer.count}')

        def command(builder):
            nonlocal sequence
            packet = builder(sequence)
            sequence += 1
            start = len(packets)
            data = packet.encode()
            transfer = usb.write(data)
            if not transfer.success or transfer.count != len(data):
                raise IOError('USB command write uncertain')
            deadline = time.monotonic()+8
            while time.monotonic() < deadline:
                read()
                for reply in packets[start:]:
                    if reply.kind == Kind.ACK:
                        number, status, reserved = struct.unpack('<IHH', reply.payload)
                        if number == packet.sequence:
                            if status or reserved:
                                raise RuntimeError(f'Command rejected: {status}/{reserved}')
                            return reply
            raise TimeoutError('FPGA command ACK timeout')

        try:
            command(lambda seq: run_command(False, seq))
            command(lambda seq: export_command(1, seq))
            display.begin_source_average(128)
            command(lambda seq: run_command(True, seq))
            deadline = time.monotonic()+3
            while len(frames) < 256 and time.monotonic() < deadline:
                read()
            if not frames:
                raise RuntimeError('No complete CCD RAW frames received')
            result = display.take_source_average()
            raw = np.asarray(frames)
            np.savez_compressed(args.output/'raw_capture.npz', frames=raw, frame_ids=ids)
            if result is not None:
                np.savez_compressed(args.output/'source_average.npz', source=result['source'],
                                    std=result['std'], count=result['count'])
            valid_ticks = np.asarray([t for t in ticks if t is not None], dtype=np.float64)
            deltas = np.diff(valid_ticks)
            report.update(raw_frames=len(frames), raw_min=int(raw.min()), raw_max=int(raw.max()),
                          raw_mean=float(raw.mean()), zero_pixels=int(np.count_nonzero(raw == 0)),
                          saturated_pixels=int(np.count_nonzero(raw == 4095)),
                          average_completed=result is not None,
                          acquisition_hz=float(1e8/np.median(deltas[deltas > 0])) if np.any(deltas > 0) else None,
                          missing_packets=display.snapshot()['missing'], bad_crc=decoder.bad_crc,
                          note='RAW cadence checks acquisition only; distance throughput and physical calibration require separate evidence.')
        except Exception as error:
            report['error'] = str(error)
        finally:
            try:
                command(lambda seq: run_command(False, seq))
                report['stop_confirmed'] = True
                command(lambda seq: export_command(100, seq))
            except Exception as error:
                report['stop_error'] = str(error)
            (args.output/'summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(report, ensure_ascii=False, indent=2))
    if 'error' in report or not report['stop_confirmed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
