"""Verify FPGA RESULT processing cadence, not physical distance accuracy.

Uploads volatile calibration only; no Flash programming. Always attempts a
graceful STOP, and records failure if no STOP ACK can be obtained.
"""
import argparse
import json
from pathlib import Path
import struct
import time

import numpy as np

from acquisition_settings import AcquisitionSettings
from protocol import (Decoder, DistanceResult, Kind, TIME_VALID, SequenceTracker,
                      run_command, acquisition_command, export_command, source_command, k_command)
from reference import Calibration, load_vector
from usb_transport import CypressUSB


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll',required=True);parser.add_argument('--source',required=True)
    parser.add_argument('--k',required=True);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--firmware-label', default='control 26092402; no resampling',
                        help='Operator-supplied label, not a USB/JTAG identity readback')
    parser.add_argument('--expect-clipping', action='store_true',
                        help='Negative test: require rail-only RAW and every RESULT invalid; not measurement acceptance')
    args=parser.parse_args()
    source=load_vector(args.source);k=load_vector(args.k)
    if len(k)!=1024:
        raise ValueError('Expected measured 1024-point K for W=40')
    settings=AcquisitionSettings(40,3000)
    cal=Calibration.create(source,k[256:768],distance_scale=.5,window_start=40)
    args.output.mkdir(parents=True,exist_ok=False)
    decoder,tracker,packets=Decoder(),SequenceTracker(),[]
    sequence=60000
    summary={'stop_confirmed':False,'firmware':args.firmware_label,
             'firmware_label_source':'operator argument; not an identity readback',
             'k_handling':'original K[256:768], unchanged; corresponds to effective pixels 296..807',
             'settings':{'W':40,'period_pixels':3000,'period_us':600},'units':'um','distance_scale':.5}
    with (args.output/'stream.spif').open('xb') as stream,CypressUSB(args.dll) as usb:
        def read():
            transfer=usb.read()
            if transfer.data:
                stream.write(transfer.data)
                for packet in decoder.feed(transfer.data):
                    tracker.observe(packet.sequence);packets.append(packet)
            if not transfer.success and not transfer.idle_timeout:
                raise IOError('USB read error')
        def command(builder):
            nonlocal sequence
            packet=builder(sequence);sequence+=1
            start=len(packets);wire=packet.encode();transfer=usb.write(wire)
            if not transfer.success or transfer.count!=len(wire):
                raise IOError('Uncertain command write')
            deadline=time.monotonic()+8
            while time.monotonic()<deadline:
                read()
                for reply in packets[start:]:
                    if reply.kind==Kind.ACK:
                        number,status,reserved=struct.unpack('<IHH',reply.payload)
                        if number==packet.sequence:
                            if status or reserved:raise RuntimeError(f'ACK rejected: {status}/{reserved}')
                            return reply
            raise TimeoutError('ACK timeout')
        try:
            command(lambda seq:run_command(False,seq))
            command(lambda seq:acquisition_command(settings,seq))
            command(lambda seq:source_command(source,seq))
            calibration_ack=command(lambda seq:k_command(cal,seq))
            command(lambda seq:export_command(100,seq))
            command(lambda seq:run_command(True,seq))
            scan=len(packets);collected=[];started=time.monotonic();deadline=started+7
            while len(collected)<5000 and time.monotonic()<deadline:
                read()
                collected.extend(p for p in packets[scan:] if p.kind==Kind.RESULT)
                scan=len(packets)
            elapsed=time.monotonic()-started
            if len(collected)<5000:raise RuntimeError(f'Only {len(collected)} RESULT packets')
            results=[DistanceResult.from_packet(p) for p in collected]
            ticks=np.diff([p.timestamp for p in collected]);frames=np.diff([p.frame_id for p in collected])
            valid=[r.distance for r in results if not r.invalid]
            raw=[np.frombuffer(p.payload,'<u2') for p in packets if p.kind==Kind.RAW]
            clipped=sum(int(np.any((r==0)|(r==4095))) for r in raw)
            summary.update(result_packets=len(collected),elapsed_seconds=elapsed,
                host_result_packet_hz=len(collected)/elapsed,host_valid_result_hz=len(valid)/elapsed,
                timestamp_result_hz=float((len(collected)-1)*1e8/(collected[-1].timestamp-collected[0].timestamp)),
                all_contiguous_frames=bool(np.all(frames==1)),all_expected_timestamps=bool(np.all(ticks==60000)),
                all_timestamps_valid=all(bool(p.flags & TIME_VALID) for p in collected),
                invalid_results=len(results)-len(valid),distance_mean_um=float(np.mean(valid)) if valid else None,
                distance_std_um=float(np.std(valid)) if valid else None,
                max_dropped_frames=max(r.dropped_frames for r in results),
                max_malformed_frames=max(r.malformed_frames for r in results),
                source_version=calibration_ack.source_version,k_version=calibration_ack.k_version,
                versions_consistent=all((p.source_version,p.k_version)==(calibration_ack.source_version,calibration_ack.k_version) for p in collected))
            summary.update(raw_frames_checked=len(raw),clipped_raw_frames=clipped,
                           rail_only_raw_frames=sum(int(np.all(r==0) or np.all(r==4095)) for r in raw),
                           optical_signal_qualified=bool(raw and clipped==0),
                           physical_distance_accuracy_verified=False,
                           note='optical_signal_qualified is a legacy non-rail RAW check only. No interference visibility or source-reference optical match is certified; rate_gate_passed checks processing throughput, not physical distance accuracy.')
        except Exception as error:summary['error']=str(error)
        finally:
            try:
                command(lambda seq:run_command(False,seq));summary['stop_confirmed']=True
            except Exception as error:summary['stop_error']=str(error)
        summary.update(bad_crc=decoder.bad_crc,bad_headers=decoder.bad_headers,bad_payloads=decoder.bad_payloads,
                       missing_packets=tracker.missing,out_of_order_packets=tracker.out_of_order)
        summary['packet_rate_gate_passed']=bool(summary.get('host_result_packet_hz',0)>=1000 and
            summary.get('all_contiguous_frames') and summary.get('all_expected_timestamps') and
            summary.get('all_timestamps_valid') and summary.get('versions_consistent') and
            summary.get('max_dropped_frames')==0 and summary.get('max_malformed_frames')==0 and
            summary['stop_confirmed'] and not any(summary[key] for key in ('bad_crc','bad_headers','bad_payloads','missing_packets','out_of_order_packets')))
        summary['rate_gate_passed']=bool(summary['packet_rate_gate_passed'] and
            summary.get('host_valid_result_hz',0)>=1000 and summary.get('optical_signal_qualified',False))
        summary['clipping_rejection_gate_passed']=bool(summary['packet_rate_gate_passed'] and
            summary.get('raw_frames_checked',0)>0 and
            summary.get('rail_only_raw_frames')==summary.get('raw_frames_checked') and
            summary.get('invalid_results')==summary.get('result_packets'))
        summary['test_mode']='clipping rejection' if args.expect_clipping else 'nonclipped input processing rate'
        (args.output/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
    print(json.dumps(summary,ensure_ascii=False,indent=2))
    gate='clipping_rejection_gate_passed' if args.expect_clipping else 'rate_gate_passed'
    if not summary[gate]:raise SystemExit(1)


if __name__=='__main__':main()
