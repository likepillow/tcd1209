"""Volatile exposure/output-rate acceptance. Always attempts STOP, never writes Flash."""
import argparse
import json
from pathlib import Path
import struct
import time

import numpy as np

from acquisition_settings import AcquisitionSettings
from protocol import (Kind, DistanceResult, TIME_VALID, acquisition_command,
                      run_command, export_command, source_command, k_command)
from recording import Recorder
from reference import Calibration, load_vector
from usb_transport import CypressUSB


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source')
    parser.add_argument('--k')
    parser.add_argument('--stop-only', action='store_true')
    parser.add_argument('--long-check', action='store_true', help='Also check 1 s cadence and interrupt a 1-hour integration tail')
    parser.add_argument('--host-pause-ms', type=float, default=0, help='Deliberate bounded IN-read pause in first case')
    args = parser.parse_args()
    if not args.stop_only and (not args.source or not args.k):
        parser.error('--source and --k are required for acquisition tests')
    source = load_vector(args.source) if args.source else None
    k = load_vector(args.k) if args.k else None
    summary = dict(stop_confirmed=False, cases=[], physical_accuracy_verified=False,
                   flash_written=False, firmware_label='exposure candidate; verify JTAG log separately')
    packets, sequence = [], 0x102400
    with Recorder(args.output, {'source_mode': 'exposure_hardware_acceptance'}) as rec, CypressUSB(args.dll) as usb:
        def read():
            transfer = usb.read()
            if transfer.data:
                rec.append(transfer.data, packets.append)
            if not transfer.success and not transfer.idle_timeout:
                raise IOError(f'USB error {transfer.error}, NT={transfer.nt_status:08x}, USBD={transfer.usbd_status:08x}, elapsed_ms={transfer.elapsed_ms}, count={transfer.count}')

        def command(builder, details=None):
            nonlocal sequence
            packet = builder(sequence);sequence += 1
            first = len(packets);wire = packet.encode();transfer = usb.write(wire)
            if not transfer.success or transfer.count != len(wire):
                raise IOError('Uncertain command write; no automatic retry')
            deadline = time.monotonic()+8
            while time.monotonic() < deadline:
                read()
                for reply in packets[first:]:
                    if reply.kind == Kind.ACK:
                        seq, status, reserved = struct.unpack('<IHH', reply.payload)
                        if seq == packet.sequence:
                            if status or reserved:
                                raise RuntimeError(f'Command rejected {status}/{reserved}')
                            rec.command_applied(packet, reply, details)
                            if packet.kind in (Kind.ACQUISITION, Kind.EXPOSURE):
                                rec.acquisition_applied(AcquisitionSettings.decode(packet.payload))
                            elif packet.kind == Kind.RUN_CONTROL:
                                rec.run_state_changed(bool(int.from_bytes(packet.payload, 'little')))
                            return reply
            raise TimeoutError('ACK timeout')

        try:
            command(lambda seq: run_command(False, seq))
            summary['stop_confirmed'] = True
            if not args.stop_only:
                # Observe high, near-1000 and low output rates; no arbitrary minimum output-rate gate.
                cases = [('200us_all', '200', 1, 3000), ('200us_1250Hz', '200', 4, 1000),
                         ('200us_833Hz', '200', 6, 500), ('600us_all', '600', 1, 1000),
                         ('10ms_all', '10000', 1, 200), ('200us_research_1k', '200', 5, 2000)]
                if args.long_check:
                    cases.append(('1s_all', '1000000', 1, 3))
                for label, exposure, stride, target in cases:
                    settings = AcquisitionSettings.from_text(40, exposure, 8, stride)
                    command(lambda seq: acquisition_command(settings, seq))
                    cal = Calibration.create(source, k[256:768] if len(k) == 1024 else k,
                                             distance_scale=.5, window_start=40)
                    command(lambda seq: source_command(source, seq))
                    ack = command(lambda seq: k_command(cal, seq), dict(source=source.tolist(), k=k.tolist(),
                        distance_scale=.5, k_units='rad/um', window_start=40,
                        period_pixels=settings.period_pixels, pixel_ticks=8))
                    raw_period = 5 if label == '200us_research_1k' else (100 if exposure != '10000' else 1)
                    command(lambda seq: export_command(raw_period, seq))
                    start = len(packets)
                    command(lambda seq: run_command(True, seq))
                    summary['stop_confirmed'] = False
                    found, first, paused = [], start, False
                    begun = time.monotonic();deadline = begun+max(8, target/settings.result_hz+3)
                    while len(found) < target and time.monotonic() < deadline:
                        read()
                        found.extend(p for p in packets[first:] if p.kind == Kind.RESULT)
                        first = len(packets)
                        if label == '200us_all' and not paused and len(found) >= 100 and args.host_pause_ms:
                            if not 0 < args.host_pause_ms <= 1000:
                                raise ValueError('Host pause must be 0..1000 ms')
                            time.sleep(args.host_pause_ms/1000);paused = True
                    elapsed = time.monotonic()-begun
                    command(lambda seq: run_command(False, seq));summary['stop_confirmed'] = True
                    if len(found) < target:
                        raise TimeoutError(f'{label}: only {len(found)} of {target} results')
                    values = [DistanceResult.from_packet(p) for p in found]
                    ticks = np.diff(np.array([p.timestamp for p in found], dtype=np.uint64))
                    frames = np.array([(b.frame_id-a.frame_id) & 0xffffffff for a, b in zip(found, found[1:])])
                    expected_ticks = settings.period_pixels*8*stride
                    raw = [np.frombuffer(p.payload, '<u2') for p in packets[start:] if p.kind == Kind.RAW]
                    pixels = np.concatenate(raw) if raw else np.array([], dtype=np.uint16)
                    case = dict(label=label, exposure_us=settings.exposure_us, result_stride=stride,
                        raw_period=raw_period,
                        nominal_result_hz=settings.result_hz, results=len(found),
                        timestamp_result_hz=float((len(found)-1)*1e8/(found[-1].timestamp-found[0].timestamp)),
                        host_result_hz=len(found)/elapsed, elapsed_seconds=elapsed,
                        injected_host_pause_ms=args.host_pause_ms if paused else 0,
                        expected_tick_step=expected_ticks, tick_steps=sorted(set(int(x) for x in ticks)),
                        frame_steps=sorted(set(int(x) for x in frames)),
                        invalid_results=sum(r.invalid for r in values), raw_frames=len(raw),
                        clipped_raw_frames=sum(int(np.any((r == 0)|(r == 4095))) for r in raw),
                        adc_min=int(pixels.min()) if pixels.size else None,
                        adc_max=int(pixels.max()) if pixels.size else None,
                        adc_mean=float(pixels.mean()) if pixels.size else None,
                        max_dropped=max(r.dropped_frames for r in values),
                        max_malformed=max(r.malformed_frames for r in values))
                    case['timing_passed'] = bool(np.all(ticks == expected_ticks) and np.all(frames == stride)
                        and all(p.flags & TIME_VALID for p in found)
                        and all((p.source_version,p.k_version)==(ack.source_version,ack.k_version) for p in found)
                        and case['max_dropped'] == 0 and case['max_malformed'] == 0)
                    if label == '200us_research_1k':
                        raw_packets = [p for p in packets[start:] if p.kind == Kind.RAW]
                        raw_steps = [(b.frame_id-a.frame_id)&0xffffffff for a,b in zip(raw_packets,raw_packets[1:])]
                        case['all_requested_raw_frames_received'] = bool(len(raw_packets) >= target and all(x == 5 for x in raw_steps))
                        case['timing_passed'] = case['timing_passed'] and case['all_requested_raw_frames_received']
                    summary['cases'].append(case)
                    if not case['timing_passed']:
                        raise RuntimeError(f'{label}: cadence/frame/version gate failed')
                if args.long_check:
                    settings = AcquisitionSettings.from_text(40, '3600000000', 8)
                    command(lambda seq: acquisition_command(settings, seq))
                    command(lambda seq: export_command(1, seq))
                    start = len(packets)
                    command(lambda seq: run_command(True, seq));summary['stop_confirmed'] = False
                    deadline = time.monotonic()+.4
                    while time.monotonic() < deadline:
                        read()
                    unexpected = sum(p.kind in (Kind.RAW, Kind.RESULT) for p in packets[start:])
                    began = time.monotonic()
                    command(lambda seq: run_command(False, seq));summary['stop_confirmed'] = True
                    latency = time.monotonic()-began
                    summary['long_tail_interrupt'] = dict(exposure_us=settings.exposure_us,
                        period_pixels=settings.period_pixels, stop_ack_seconds=latency,
                        unexpected_measurements_before_full_integration=unexpected,
                        passed=bool(latency < 2 and unexpected == 0))
                    if not summary['long_tail_interrupt']['passed']:
                        raise RuntimeError('Long integration stop/quiet check failed')
                # Leave a practical stopped period, not an hours-long exposure or stale test S/K.
                ack = command(lambda seq: acquisition_command(AcquisitionSettings.from_text(40, '600', 8), seq))
                summary['handoff'] = dict(window_start=40, exposure_us=600, result_stride=1,
                    source_version=ack.source_version, k_version=ack.k_version,
                    note='Stopped; collect/upload matching S/K before measurement')
        except Exception as error:
            summary['error'] = str(error)
        finally:
            try:
                command(lambda seq: run_command(False, seq));summary['stop_confirmed'] = True
            except Exception as error:
                summary['stop_error'] = str(error)
        d = rec.decoder
        summary.update(bad_crc=d.bad_crc, bad_headers=d.bad_headers, bad_payloads=d.bad_payloads,
                       missing_packets=rec.sequence.missing, out_of_order_packets=rec.sequence.out_of_order)
        summary['passed'] = bool(summary['stop_confirmed'] and 'error' not in summary and not any(summary[k]
            for k in ('bad_crc', 'bad_headers', 'bad_payloads', 'missing_packets', 'out_of_order_packets')))
    (args.output/'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    if not summary['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
