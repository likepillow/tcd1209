"""CCD acquisition settings shared by the GUI and wire codec.

T is the SH-to-SH period of the qualified 5 MHz readout profile. Restricting
it below 1 ms retains a nominal acquisition rate greater than 1000 Hz.
"""
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
import struct


@dataclass(frozen=True)
class AcquisitionSettings:
    window_start: int = 512
    period_pixels: int = 2114

    def __post_init__(self):
        if type(self.window_start) is not int or not 0 <= self.window_start <= 1024:
            raise ValueError('S0 起点 W 必须是 0～1024 的整数（零基下标）')
        if type(self.period_pixels) is not int or not 2114 <= self.period_pixels <= 4999:
            raise ValueError('曝光周期 T 必须在 422.8～999.8 μs 范围内')

    @classmethod
    def from_text(cls, window_start, exposure_us):
        try:
            w = Decimal(str(window_start).strip())
            t = Decimal(str(exposure_us).strip())
        except InvalidOperation as error:
            raise ValueError('W 和 T 必须是有效数值') from error
        if not w.is_finite() or w != w.to_integral_value():
            raise ValueError('W 必须是整数')
        if not t.is_finite() or t * 5 != (t * 5).to_integral_value():
            raise ValueError('T 必须为 0.2 μs 的整数倍')
        return cls(int(w), int(t * 5))

    @property
    def exposure_us(self):
        return self.period_pixels / 5

    @property
    def nominal_hz(self):
        return 5_000_000 / self.period_pixels

    def encode(self):
        return struct.pack('<II', self.window_start, self.period_pixels)

    @classmethod
    def decode(cls, payload):
        if len(payload) != 8:
            raise ValueError('ACQUISITION payload must contain W and period_pixels')
        return cls(*struct.unpack('<II', payload))
