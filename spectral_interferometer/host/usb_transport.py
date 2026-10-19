"""Serialized CyUSB RPC adapter; opening does not download/reset the device.

The receive worker owns this object. GUI commands must be queued to that worker,
not sent concurrently. Transfer failure and partial bytes are reported explicitly.
"""
from dataclasses import dataclass
from pathlib import Path
import struct
import subprocess
import sys


@dataclass(frozen=True)
class Transfer:
    success: bool
    count: int
    error: int
    data: bytes = b''
    nt_status: int = 0
    usbd_status: int = 0
    elapsed_ms: int = 0

    @property
    def idle_timeout(self):
        # Only the observed 200 ms IN timeout/cancellation combination is
        # accepted. ERROR_IO_PENDING alone is not proof of an idle timeout.
        return (not self.success and self.count == 0 and not self.data and
                (self.error == 121 or
                 (self.error == 997 and self.nt_status == 0xC0000120 and
                  self.usbd_status == 0xC0010000 and self.elapsed_ms >= 200)))


class CypressUSB:
    def __init__(self, dll):
        # PyInstaller extracts bundled data below sys._MEIPASS. Source-tree
        # execution keeps the historical project-root-relative lookup.
        resource_root = Path(getattr(sys, '_MEIPASS', Path(__file__).resolve().parents[1]))
        script = resource_root/'scripts'/'run_cypress_transport.ps1'
        self.process = subprocess.Popen(
            ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
             str(script), '-CyUsbDll', str(Path(dll).resolve())],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            if self._read_exact(4) != b'FX22':
                raise IOError('Invalid Cypress transport handshake')
        except BaseException:
            self.close()
            raise

    def _read_exact(self, count):
        data = bytearray()
        while len(data) < count:
            chunk = self.process.stdout.read(count-len(data))
            if not chunk:
                raise IOError('Cypress transport closed unexpectedly')
            data.extend(chunk)
        return bytes(data)

    def _transfer(self, opcode, count, data=b''):
        if not 1 <= count <= 65536:
            raise ValueError('USB transfer length must be 1..65536')
        self.process.stdin.write(struct.pack('<BI', opcode, count)+data)
        self.process.stdin.flush()
        status, actual, error, nt, usbd, elapsed = struct.unpack('<BiiIII', self._read_exact(21))
        if status not in (0, 1) or not 0 <= actual <= count:
            raise IOError('Invalid Cypress transfer response')
        payload = self._read_exact(actual) if opcode == 1 else b''
        return Transfer(status == 0, actual, error, payload, nt, usbd, elapsed)

    def read(self, count=16384):
        return self._transfer(1, count)

    def write(self, data):
        data = bytes(data)
        return self._transfer(2, len(data), data)

    def close(self):
        if self.process.poll() is None:
            try:
                self.process.stdin.write(b'\0')
                self.process.stdin.flush()
                self.process.wait(timeout=3)
            except (OSError, subprocess.TimeoutExpired):
                self.process.kill()
                self.process.wait()
        # A helper that fails before the handshake may already have torn down
        # either pipe; cleanup must not mask the original diagnostic.
        for pipe in (self.process.stdin, self.process.stdout):
            try:
                pipe.close()
            except OSError:
                pass

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()
