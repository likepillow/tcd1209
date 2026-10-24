"""Reproducible host checks; never opens USB or programs FPGA/Flash."""
import argparse
import io
import json
from pathlib import Path
import platform
import struct
import sys
import tempfile
import time
import tracemalloc
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT/'build/d1_dependencies'), str(ROOT/'host'), str(ROOT/'sim')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--benchmark-frames', type=int, default=0)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    log = io.StringIO()
    started = time.monotonic()
    suite = unittest.defaultTestLoader.discover(str(ROOT/'sim'), pattern='test_*.py')
    result = unittest.TextTestRunner(stream=log, verbosity=2).run(suite)
    (args.output/'tests.txt').write_text(log.getvalue(), encoding='utf-8')
    report = dict(python=platform.python_version(), tests=result.testsRun,
                  failures=len(result.failures), errors=len(result.errors), skipped=len(result.skipped),
                  test_seconds=time.monotonic()-started, hardware_tested=False,
                  flash_modified=False)
    if result.wasSuccessful() and args.benchmark_frames > 0:
        from protocol import Packet, Kind, TIME_VALID
        from session_recording import AsyncSessionRecorder, verify_session
        with tempfile.TemporaryDirectory(dir=args.output) as folder:
            target = Path(folder)/'capture'
            tracemalloc.start()
            start = time.monotonic()
            recorder = AsyncSessionRecorder(target, volume_bytes=8 << 20)
            payload = bytes(12)+struct.pack('<hHHHII', 0, 1, 1, 1, 0, 0)
            for frame in range(args.benchmark_frames):
                raw = Packet(Kind.RAW, frame*2, frame, bytes(2048), frame*100000, flags=TIME_VALID)
                distance = Packet(Kind.RESULT, frame*2+1, frame, payload, frame*100000, flags=TIME_VALID)
                recorder.append(raw.encode()+distance.encode())
            recorder.close(device_stop_confirmed=None, stop_reason='synthetic_benchmark')
            elapsed = time.monotonic()-start
            _, peak = tracemalloc.get_traced_memory()
            tracemalloc.stop()
            verification = verify_session(target)
            report['synthetic_benchmark'] = dict(frames=args.benchmark_frames,
                packets=verification['packets'], seconds=elapsed,
                frames_per_second=args.benchmark_frames/elapsed,
                python_traced_peak_bytes=peak, integrity_ok=verification['transport_integrity_ok'],
                peak_queue_bytes=recorder.peak_bytes,
                note='Synthetic CPU/disk run with tracing overhead; not USB or 10min/1h/8h acceptance.')
            (args.output/'benchmark_manifest.json').write_bytes((target/'manifest.json').read_bytes())
    (args.output/'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps(report, indent=2))
    if not result.wasSuccessful():
        raise SystemExit(1)


if __name__ == '__main__':
    main()
