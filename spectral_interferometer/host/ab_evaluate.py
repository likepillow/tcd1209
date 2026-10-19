"""Evaluate current, linear-K and cubic-K distance paths on a common NPZ dataset.

Dataset keys: frames[M,1024 or 2048], source[1024 or 2048],
k[1024 or 2048], truth[M].  Results use one additive zero correction derived
only from the first truth position; no scale fit is performed.
"""
import argparse
import csv
import json
from pathlib import Path
import sys
import time

import numpy as np

from reference import Calibration, solve
from resampling import solve_resampled
from protocol import INVALID


def evaluate(path, output, distance_scale=1.0, window_start=512):
    with np.load(path, allow_pickle=False) as data:
        frames = np.asarray(data['frames'], dtype=float)
        source = np.asarray(data['source'], dtype=float)
        k = np.asarray(data['k'], dtype=float)
        truth = np.asarray(data['truth'], dtype=float)
        flags = np.asarray(data['flags'], dtype=np.uint32) if 'flags' in data else np.zeros(len(frames), dtype=np.uint32)
        if 'window_start' in data and int(data['window_start']) != window_start:
            raise ValueError('Dataset W does not match requested window_start')
    if (frames.ndim != 2 or frames.shape[1] not in (1024, 2048) or
            not len(frames) or truth.shape != (len(frames),) or
            not np.all(np.isfinite(truth)) or flags.shape != (len(frames),)):
        raise ValueError('frames must be 2-D and truth must contain one value per frame')
    cal = Calibration.create(source, k, distance_scale=distance_scale,
                             window_start=window_start)
    rows = []
    for index, (frame, expected) in enumerate(zip(frames, truth)):
        row = dict(index=index, truth=float(expected))
        for method in ('current', 'linear', 'cubic'):
            start = time.perf_counter()
            try:
                if flags[index] & INVALID:
                    raise ValueError('CCD packet carries INVALID flag')
                result = (solve(frame, cal) if method == 'current' else
                          solve_resampled(frame, source, k, method=method,
                                          distance_scale=distance_scale, window_start=window_start))
                row[method] = result['distance']
                row[method+'_error_reason'] = ''
                row[method+'_peak_width'] = result['band_right']-result['band_left']+1
                power = np.abs(result['H0'])**2
                noise = power[1:512].copy()
                left, right = result['band_left'], result['band_right']
                mask = np.ones(511, dtype=bool)
                mask[left-1:right] = False
                floor = float(np.median(noise[mask])) if np.any(mask) else float('nan')
                peak_power = float(power[result['peak_bin']])
                row[method+'_peak_snr_db'] = (float(10*np.log10(peak_power/max(floor, np.finfo(float).tiny)))
                                              if np.isfinite(floor) else float('nan'))
                if method == 'linear':
                    for name in ('coarse_integer', 'coarse_parabolic', 'coarse_log'):
                        row[name] = result[name]
            except ValueError as error:
                row[method] = float('nan')
                row[method+'_error_reason'] = str(error)
                row[method+'_peak_width'] = float('nan')
                row[method+'_peak_snr_db'] = float('nan')
                if method == 'linear':
                    for name in ('coarse_integer', 'coarse_parabolic', 'coarse_log'):
                        row[name] = float('nan')
            row[method+'_elapsed_us'] = (time.perf_counter()-start)*1e6
        rows.append(row)
    first_truth = truth[0]
    reference = np.flatnonzero(truth == first_truth)
    methods = ('current', 'linear', 'cubic', 'coarse_integer', 'coarse_parabolic', 'coarse_log')
    summary = {}
    for method in methods:
        measured = np.array([row[method] for row in rows])
        valid = np.isfinite(measured)
        ref_valid = reference[valid[reference]]
        zero = float(np.median(measured[ref_valid]-truth[ref_valid])) if len(ref_valid) else float('nan')
        corrected = measured-zero
        error = corrected-truth
        for row, value, deviation in zip(rows, corrected, error):
            row[method+'_corrected'] = float(value)
            row[method+'_error'] = float(deviation)
        per_truth_std = [np.std(corrected[(truth == value) & valid], ddof=1)
                         for value in np.unique(truth) if np.count_nonzero((truth == value) & valid) > 1]
        good_error = error[np.isfinite(error)]
        summary[method] = dict(zero_offset=zero if np.isfinite(zero) else None,
                               valid_frames=int(np.count_nonzero(valid)),
                               invalid_rate=float(np.mean(~valid)),
                               bias=float(np.mean(good_error)) if len(good_error) else None,
                               p95_abs_error=float(np.percentile(np.abs(good_error), 95)) if len(good_error) else None,
                               max_abs_error=float(np.max(np.abs(good_error))) if len(good_error) else None,
                               worst_repeatability_std=float(max(per_truth_std)) if per_truth_std and np.isfinite(zero) else None)
        if method in ('current', 'linear', 'cubic'):
            summary[method]['mean_elapsed_us'] = float(np.mean([r[method+'_elapsed_us'] for r in rows]))
            summary[method]['p95_elapsed_us'] = float(np.percentile([r[method+'_elapsed_us'] for r in rows], 95))
            for key in ('peak_width', 'peak_snr_db'):
                finite = np.array([r[method+'_'+key] for r in rows])
                finite = finite[np.isfinite(finite)]
                summary[method]['median_'+key] = float(np.median(finite)) if len(finite) else None
        position_bias = [float(np.mean(error[(truth == value) & np.isfinite(error)]))
                         for value in np.unique(truth) if np.any((truth == value) & np.isfinite(error))]
        span = float(np.ptp(truth))
        summary[method]['full_range_nonlinearity_fraction'] = (
            max(abs(bias) for bias in position_bias)/span if position_bias and span > 0 else None)
    current, linear, cubic = (summary[name] for name in ('current', 'linear', 'cubic'))
    def better(before, after, key, factor):
        a, b = before[key], after[key]
        return a is not None and b is not None and a > 0 and b <= factor*a

    def close_to_reference(key):
        a, b = linear[key], cubic[key]
        return a is not None and b is not None and a <= 1.05*max(b, 1e-30)

    counts = [int(np.count_nonzero(truth == value)) for value in np.unique(truth)]
    enough_data = len(counts) >= 11 and min(counts) >= 500
    metrics_pass = (better(current, linear, 'p95_abs_error', .8) or
                    better(current, linear, 'worst_repeatability_std', .8) or
                    (current['invalid_rate'] > 0 and linear['invalid_rate'] == 0))
    summary['decision'] = {
        'minimum_position_sample_counts_met': enough_data,
        'metrics_pass': bool(metrics_pass),
        'implement_resampling': bool(enough_data and metrics_pass and linear['zero_offset'] is not None
                                     and linear['invalid_rate'] <= current['invalid_rate']),
        'linear_within_5_percent_of_cubic': bool(close_to_reference('p95_abs_error') and
                                                close_to_reference('worst_repeatability_std')),
        'physical_data_review_required': True,
        'rule': '>=11 positions and >=500 frames/position; >=20% P95 OR worst repeatability gain, OR elimination of invalid frames; physical provenance and static/fine-scan gates require review'}
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    with (output/'per_frame.csv').open('w', newline='', encoding='utf-8-sig') as stream:
        writer = csv.DictWriter(stream, fieldnames=rows[0].keys())
        writer.writeheader(); writer.writerows(rows)
    (output/'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding='utf-8')
    report = ['# 非均匀 K 重采样 A/B 结果', '', f'输入：`{Path(path).resolve()}`', '',
              '|方法|P95绝对误差|最差重复性标准差|最大绝对误差|', '|---|---:|---:|---:|']
    for method in methods:
        item = summary[method]
        report.append('|'+method+'|'+ '|'.join('N/A' if item[key] is None else f'{item[key]:.8g}'
                      for key in ('p95_abs_error', 'worst_repeatability_std', 'max_abs_error'))+'|')
    report += ['', '```json', json.dumps(summary['decision'], ensure_ascii=False, indent=2), '```']
    (output/'report.md').write_text('\n'.join(report)+'\n', encoding='utf-8')
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dataset', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--distance-scale', type=float, default=1.0)
    parser.add_argument('--window-start', type=int, default=512)
    args = parser.parse_args()
    result = evaluate(args.dataset, args.output, args.distance_scale, args.window_start)
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2); print()


if __name__ == '__main__':
    main()
