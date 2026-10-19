"""Validate first-profile ILA telemetry, without claiming optical validity."""
import argparse
import csv
import json
from pathlib import Path


def analyze(rows):
    if len(rows) != 8192:
        raise ValueError(f"Expected 8192 qualified samples, found {len(rows)}")
    frames = []
    for number in range(4):
        block = rows[number * 2048:(number + 1) * 2048]
        frame_id = int(block[0]["frame_id[31:0]"], 16)
        timestamp = int(block[0]["timestamp[63:0]"], 16)
        data, raw = [], []
        for index, row in enumerate(block):
            expected = {"index[10:0]": index, "frame_id[31:0]": frame_id,
                        "timestamp[63:0]": timestamp, "first_1": int(index == 0),
                        "last_1": int(index == 2047), "valid_1": 1,
                        "fault_1": 0, "busy_1": 1, "configured_1": 1,
                        "locked_1": 1, "board_reset_n_1": 1,
                        "release_pipe_1[3:3]": 1, "run_1": 1, "hold_reset_1": 0}
            for field, value in expected.items():
                if int(row[field], 16) != value:
                    raise ValueError(f"Frame {number} pixel {index}: wrong {field}")
            if int(row["Sample in Buffer"]) != number * 2048 + index:
                raise ValueError("Nonconsecutive buffer samples")
            value = int(row["data[11:0]"], 16)
            raw_value = int(row["ad_data_IBUF[11:0]"], 16)
            if not 0 <= value <= 4095 or not 0 <= raw_value <= 4095:
                raise ValueError("ADC value exceeds 12 bits")
            data.append(value)
            raw.append(raw_value)
        if frames:
            if frame_id != (frames[-1]["frame_id"] + 1) & 0xffffffff:
                raise ValueError("Nonconsecutive frame IDs")
            if timestamp - frames[-1]["timestamp_ticks"] != 42280:
                raise ValueError("Frame timestamp period is not 422.8 us")
        frames.append({"frame_id": frame_id, "timestamp_ticks": timestamp,
                       "pixels": len(data), "adc_min": min(data), "adc_max": max(data),
                       "adc_mean": sum(data) / len(data), "adc_unique": len(set(data)),
                       "raw_adc_min": min(raw), "raw_adc_max": max(raw),
                       "zero_pixels": data.count(0), "saturated_pixels": data.count(4095)})
    return {"framing_valid": True, "qualified_samples": len(rows),
            "frame_period_us": 422.8, "frames": frames,
            "all_adc_zero": all(f["zero_pixels"] == 2048 for f in frames),
            "optical_validity": "unverified; first frame has unknown exposure",
            "transport": "JTAG ILA, not USB streaming"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    with args.capture.open(newline="", encoding="utf-8-sig") as stream:
        result = analyze(list(csv.DictReader(stream)))
    text = json.dumps(result, indent=2, ensure_ascii=False)
    print(text)
    if args.report:
        with args.report.open("x", encoding="utf-8") as stream:
            stream.write(text + "\n")
