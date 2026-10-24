"""Loss-visible recording/replay backend, independent of GUI refresh rate.

The acquisition worker calls append with every received transport chunk. Raw
bytes are saved before decoding, including corrupt packets for later diagnosis.
No USB device implementation is provided by this module.
"""
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
import argparse
import csv
import json
import os
import time

from protocol import Decoder, DistanceResult, Kind, SequenceTracker, TIME_VALID, DISCONTINUITY


class Recorder:
    def __init__(self, directory, metadata=None):
        # Exclusive directory creation prevents silently overwriting a session.
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=False)
        self.metadata = dict(metadata or {})
        self.decoder = Decoder()
        self.sequence = SequenceTracker()
        self.received_bytes = 0
        self.results = 0
        self.invalid_results = 0
        self.discontinuity_packets = 0
        self.closed = False
        self.started_utc = datetime.now(timezone.utc).isoformat()
        self.started_monotonic = time.monotonic()
        self._raw = self._csv_file = None
        try:
            self._write_status(False, None)
            self._raw = (self.directory/'stream.spif').open('xb')
            self._csv_file = (self.directory/'distance.csv').open('x', newline='', encoding='utf-8')
            self._csv = csv.writer(self._csv_file)
            self._csv.writerow(['sequence', 'frame_id', 'timestamp_ticks', 'source_version', 'k_version',
                                'flags', 'invalid', 'accumulator', 'exponent', 'distance',
                                'peak', 'left', 'right', 'dropped_frames', 'malformed_frames'])
        except BaseException:
            for stream in (self._raw, self._csv_file):
                if stream is not None:
                    stream.close()
            raise

    def _write_status(self, clean, error):
        status = {'format': 'SPIF v1', 'started_utc': self.started_utc,
                  'closed_cleanly': clean, 'error': error, 'metadata': self.metadata,
                  'received_bytes': self.received_bytes, 'packets': self.decoder.packets,
                  'bad_headers': self.decoder.bad_headers, 'bad_crc': self.decoder.bad_crc,
                  'bad_payloads': self.decoder.bad_payloads, 'discarded_bytes': self.decoder.discarded_bytes,
                  'missing_packets': self.sequence.missing, 'out_of_order_packets': self.sequence.out_of_order,
                  'results': self.results, 'invalid_results': self.invalid_results,
                  'discontinuity_packets': self.discontinuity_packets}
        status['transport_integrity_ok'] = clean and not any(status[key] for key in
            ('bad_headers', 'bad_crc', 'bad_payloads', 'discarded_bytes', 'missing_packets', 'out_of_order_packets', 'discontinuity_packets'))
        temporary = self.directory/'manifest.json.tmp'
        with temporary.open('w', encoding='utf-8') as stream:
            json.dump(status, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, self.directory/'manifest.json')

    def append(self, chunk, on_packet=None):
        """Called by a single acquisition worker, not concurrently by UI threads.

        Disk/callback errors propagate; the caller must stop and report failure,
        never continue claiming lossless saving. Callback should only update a
        latest-frame slot/queue, not perform synchronous plotting.
        """
        if self.closed:
            raise ValueError('Recording is closed')
        self._raw.write(chunk)
        self.received_bytes += len(chunk)
        for packet in self.decoder.feed(chunk):
            self.sequence.observe(packet.sequence)
            self.discontinuity_packets += int(bool(packet.flags & DISCONTINUITY))
            if packet.kind == Kind.RESULT:
                result = DistanceResult.from_packet(packet)
                self.results += 1
                self.invalid_results += int(result.invalid)
                self._csv.writerow([packet.sequence, packet.frame_id,
                    packet.timestamp if packet.flags & TIME_VALID else '', packet.source_version,
                    packet.k_version, packet.flags, int(result.invalid), result.accumulator,
                    result.exponent, '' if result.invalid else result.distance,
                    result.peak, result.left, result.right, result.dropped_frames, result.malformed_frames])
            if on_packet is not None:
                on_packet(packet)

    def flush(self):
        if self.closed:
            raise ValueError('Recording is closed')
        for stream in (self._raw, self._csv_file):
            stream.flush()
            os.fsync(stream.fileno())
        self._write_status(False, None)

    def acquisition_applied(self, settings):
        """Persist the exact acknowledged boundary for later curve coordinates."""
        events = self.metadata.setdefault('acquisition_events', [])
        events.append({'after_packet': self.decoder.packets,
                       'window_start': settings.window_start,
                       'period_pixels': settings.period_pixels,
                       'pixel_ticks': settings.pixel_ticks,
                       'result_stride': settings.result_stride})
        self._write_status(False, None)

    def command_applied(self, command, ack, details=None):
        event = dict(after_packet=self.decoder.packets, kind=int(command.kind),
                     sequence=command.sequence, payload_hex=command.payload.hex(),
                     source_version=ack.source_version, k_version=ack.k_version)
        if details is not None:
            event['calibration'] = details
        self.configuration_event(event)

    def configuration_event(self, event):
        self.metadata.setdefault('configuration_events', []).append(dict(event, after_packet=self.decoder.packets))
        self._write_status(False, None)

    def run_state_changed(self, running):
        """Persist acknowledged run boundaries in the same USB session."""
        if not isinstance(running, bool):
            raise TypeError('running must be bool')
        events = self.metadata.setdefault('run_events', [])
        events.append({'after_packet': self.decoder.packets,
                       'running': running,
                       'elapsed_seconds': time.monotonic()-self.started_monotonic})
        self._write_status(False, None)

    def close(self, error=None):
        if self.closed:
            return
        try:
            if error is None:
                try:
                    self.decoder.finish()
                except ValueError as problem:
                    error = str(problem)
            self.flush()
            self._write_status(error is None, error)
        finally:
            self.closed = True
            self._raw.close()
            self._csv_file.close()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_value, traceback):
        self.close(None if exc_value is None else str(exc_value))


def replay(path, chunk_size=65536):
    """Yield verified packets; raise at EOF if ANY corruption/gap/truncation.

    Earlier packets can be inspected before the final integrity verdict. The UI
    must not call a replay successful until the iterator reaches clean EOF.
    """
    if chunk_size <= 0:
        raise ValueError('chunk_size must be positive')
    from session_recording import iter_chunks, load_manifest, session_directory
    directory = session_directory(path)
    manifest = load_manifest(path) if directory else None
    decoder = Decoder()
    sequence = SequenceTracker()
    for chunk in iter_chunks(path, chunk_size):
        for packet in decoder.feed(chunk):
            sequence.observe(packet.sequence)
            if packet.flags & DISCONTINUITY:
                raise ValueError('Device explicitly marked a discontinuity')
            yield packet
    decoder.finish()
    if (decoder.bad_headers or decoder.bad_crc or decoder.bad_payloads or decoder.discarded_bytes
            or sequence.missing or sequence.out_of_order):
        raise ValueError('Recording has corruption, missing packets or out-of-order packets')
    if manifest and not manifest['closed_cleanly']:
        raise ValueError('Session did not close cleanly; use recovery to inspect committed evidence')


def main():
    parser = argparse.ArgumentParser(description='Verify/replay a saved SPIF byte stream (no live USB connection)')
    parser.add_argument('stream', type=Path)
    args = parser.parse_args()
    packets = results = 0
    for packet in replay(args.stream):
        packets += 1
        if packet.kind == Kind.RESULT:
            result = DistanceResult.from_packet(packet)
            results += 1
            print(json.dumps({'frame_id': packet.frame_id, 'source_version': packet.source_version,
                              'k_version': packet.k_version, **asdict(result),
                              'distance': None if result.invalid else result.distance}, allow_nan=False))
    print(f'PASS: {packets} verified packets, {results} distance records; clean EOF')


if __name__ == '__main__':
    main()
