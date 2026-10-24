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
    pixel_ticks: int = 20
    result_stride: int = 1

    def __post_init__(self):
        if type(self.window_start) is not int or not 0 <= self.window_start <= 1024:
            raise ValueError('S0 起点 W 必须是 0～1024 的整数（零基下标）')
        if type(self.pixel_ticks) is not int or self.pixel_ticks not in (8, 20):
            raise ValueError('像素时钟配置必须为5 MHz或12.5 MHz')
        lo, hi = (2114, 4999) if self.pixel_ticks == 20 else (2500, 2**61-1)
        if type(self.period_pixels) is not int or not lo <= self.period_pixels <= hi:
            raise ValueError('旧版T须422.8～999.8 μs；新版T须≥200 μs且计数不溢出')
        if type(self.result_stride) is not int or not 1 <= self.result_stride <= 2**32-1:
            raise ValueError('距离输出间隔必须为1～4294967295帧')
        if self.pixel_ticks == 20 and self.result_stride != 1:
            raise ValueError('旧版固件不支持独立距离输出间隔')

    @classmethod
    def from_text(cls, window_start, exposure_us, pixel_ticks=20, result_stride=1):
        try:
            w = Decimal(str(window_start).strip())
            t = Decimal(str(exposure_us).strip())
        except InvalidOperation as error:
            raise ValueError('W 和 T 必须是有效数值') from error
        if not w.is_finite() or w != w.to_integral_value():
            raise ValueError('W 必须是整数')
        if not t.is_finite():
            raise ValueError('T 必须有限')
        pixels = t * 100 / pixel_ticks
        if pixels != pixels.to_integral_value():
            raise ValueError('T 步进为旧版0.2、新版0.08 μs')
        return cls(int(w), int(pixels), pixel_ticks, result_stride)

    @property
    def exposure_us(self):
        return self.period_pixels * self.pixel_ticks / 100

    @property
    def nominal_hz(self):
        return 100_000_000 / (self.period_pixels*self.pixel_ticks)

    @property
    def result_hz(self):
        return self.nominal_hz/self.result_stride

    def encode(self):
        if self.pixel_ticks == 8:
            return struct.pack('<IQI', self.window_start, self.period_pixels, self.result_stride)
        return struct.pack('<II', self.window_start, self.period_pixels)

    @classmethod
    def decode(cls, payload):
        if len(payload) == 16:
            w, p, stride = struct.unpack('<IQI', payload)
            return cls(w, p, 8, stride)
        if len(payload) != 8:
            raise ValueError('ACQUISITION payload must contain W and period_pixels')
        return cls(*struct.unpack('<II', payload))
