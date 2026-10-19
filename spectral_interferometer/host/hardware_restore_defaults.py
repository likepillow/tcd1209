"""Leave the connected instrument in documented handoff state."""
import argparse
import json
import struct
import time

from acquisition_settings import AcquisitionSettings
from protocol import Decoder, Kind, acquisition_command, export_command
from usb_transport import CypressUSB


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dll', required=True)
    parser.add_argument('--timeout', type=float, default=8.0)
    args = parser.parse_args()
    decoder = Decoder()

    def send(usb, command):
        encoded = command.encode()
        transfer = usb.write(encoded)
        if not transfer.success or transfer.count != len(encoded):
            raise IOError('USB command write failed')
        deadline = time.monotonic() + args.timeout
        while time.monotonic() < deadline:
            transfer = usb.read()
            for packet in decoder.feed(transfer.data):
                if packet.kind == Kind.ACK:
                    sequence, status, reserved = struct.unpack('<IHH', packet.payload)
                    if sequence == command.sequence:
                        if status or reserved:
                            raise RuntimeError(f'Command rejected: {status}/{reserved}')
                        return packet
            if not transfer.success and not transfer.idle_timeout:
                raise IOError(f'USB read failed: {transfer.error}')
        raise TimeoutError(f'ACK timeout: {command.sequence}')

    with CypressUSB(args.dll) as usb:
        acquisition_ack = send(usb, acquisition_command(AcquisitionSettings(512, 2114), 400))
        export_ack = send(usb, export_command(100, 401))
    if acquisition_ack.source_version or acquisition_ack.k_version:
        raise RuntimeError('W/T reset did not clear S/K versions')
    result = dict(result='PASS', window_start=512, exposure_us=422.8,
                  nominal_hz=AcquisitionSettings().nominal_hz,
                  export_period_frames=100, source_version=0, k_version=0,
                  bad_crc=decoder.bad_crc, bad_payloads=decoder.bad_payloads)
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
