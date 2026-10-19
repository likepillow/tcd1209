"""Summarize logical pin transitions in a 100 MHz, ALWAYS-mode ILA CSV.

These are internal output nets, not measurements of electrical pin levels.
"""
import argparse
import csv
import json
from collections import Counter


def analyze(path):
    with open(path, newline="", encoding="utf-8-sig") as stream:
        rows = list(csv.DictReader(stream))
    pins = [int(row["output_pins[12:0]"], 16) for row in rows]
    result = {"samples": len(rows), "sample_period_ns": 10,
              "scope": "FPGA internal output nets; NOT electrical pin measurements"}
    for name, bit in {"SH": 10, "RS": 9, "CP": 8, "DATACLK": 5}.items():
        values = [(word >> bit) & 1 for word in pins]
        rises = [i for i in range(1, len(values)) if values[i] > values[i-1]]
        falls = [i for i in range(1, len(values)) if values[i] < values[i-1]]
        widths = [next(f for f in falls if f > r) - r for r in rises
                  if any(f > r for f in falls)]
        result[name] = {"rising_samples": rises if name == "SH" else rises[:5],
                        "falling_samples": falls if name == "SH" else falls[:5],
                        "complete_high_width_ns_counts": dict(Counter(w * 10 for w in widths)),
                        "rising_interval_ns_counts": dict(Counter((b-a)*10 for a,b in zip(rises, rises[1:])))}
    result["phi_complement_errors"] = sum(((p >> 12) & 1) == ((p >> 11) & 1) for p in pins)
    result["frame_start_samples"] = [i for i,r in enumerate(rows) if int(r["frame_start_1"],16)]
    result["fault_samples"] = sum(int(r["fault_1"],16) != 0 for r in rows)
    sh_indices = [i for i,p in enumerate(pins) if (p >> 10) & 1]
    result["RS_or_CP_high_during_SH_samples"] = sum(bool(pins[i] & ((1 << 9) | (1 << 8))) for i in sh_indices)
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture")
    parser.add_argument("--report")
    args = parser.parse_args()
    result = analyze(args.capture)
    output = json.dumps(result, indent=2, ensure_ascii=False)
    if args.report:
        with open(args.report, "x", encoding="utf-8") as stream:
            stream.write(output + "\n")
    print(output)
