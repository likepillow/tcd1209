"""Controlled offline experiment on the user's 11-step 5 um capture.

K isotonic projection is explicitly diagnostic and never uploaded. Baseline
phase fitting uses the original central 512 K values without alteration.
"""
import argparse
import csv
import json
import hashlib
from pathlib import Path
import time

import numpy as np

from reference import Calibration, solve
from resampling import solve_resampled
from protocol import DISCONTINUITY


def isotonic_k(values):
    blocks=[]
    for value in values:
        blocks.append([float(value),1])
        while len(blocks)>1 and blocks[-2][0]>blocks[-1][0]:
            b=blocks.pop();a=blocks.pop()
            blocks.append([(a[0]*a[1]+b[0]*b[1])/(a[1]+b[1]),a[1]+b[1]])
    result=np.repeat([a[0] for a in blocks],[a[1] for a in blocks])
    # Strict monotonic epsilon is <=0.001 of the smallest measured positive step.
    positive=np.diff(values);epsilon=float(np.min(positive[positive>0]))*.001
    for i in range(1,len(result)):
        result[i]=max(result[i],result[i-1]+epsilon)
    return result


def smooth_source(source,width):
    return np.convolve(np.pad(source,width//2,mode='reflect'),np.ones(width)/width,mode='valid')


def read_revised_k(path):
    import io
    raw=Path(path).read_bytes()
    k=np.loadtxt(io.BytesIO(raw))
    if k.shape!=(1024,) or not np.all(np.isfinite(k)) or not np.all(k>0) or not np.all(np.diff(k)>0):
        raise ValueError('Revised K must contain exactly 1024 positive finite strictly increasing values; no automatic repair')
    return k,raw


def run(input_path,output,limit=1000,include_discontinuity=False,k_override=None):
    output=Path(output);output.mkdir(parents=True,exist_ok=False)
    with np.load(input_path) as data:
        frames=data['frames'];truth=data['truth'];source=data['source'];k=data['k']
        frame_ids=data['frame_ids'];flags=data['flags'];means=data['means']
    k_provenance={'origin':'cached samples.npz K', 'override':False}
    if k_override is not None:
        path=Path(k_override)
        k,raw=read_revised_k(path)
        # Preserve the exact file used even if the user's source changes later.
        (output/'K_revised_input.txt').write_bytes(raw)
        k_provenance={'origin':str(path.resolve()),'override':True,
                      'sha256':hashlib.sha256(raw).hexdigest(),
                      'sample_file_sha256':hashlib.sha256(Path(input_path).read_bytes()).hexdigest()}
    repaired=k.copy() if np.all(np.diff(k)>0) else isotonic_k(k)
    np.savetxt(output/'K_diagnostic_monotonic.txt',repaired,fmt='%.12g',
               header='DIAGNOSTIC ONLY: isotonic projection of supplied K; no hardware upload')
    sources={'original':source,'box31':smooth_source(source,31),'box101':smooth_source(source,101)}
    rows=[]
    # The zero/step direction is fixed globally to decreasing absolute distance.
    for source_name,s in sources.items():
        cal=Calibration.create(s,k[256:768],distance_scale=.5,window_start=40)
        for pos in np.unique(truth):
            selected=np.flatnonzero((truth==pos)&(include_discontinuity | ((flags & DISCONTINUITY)==0)))[:limit]
            for index in selected:
                for method in ('current','linear','cubic'):
                    started=time.perf_counter()
                    try:
                        result=(solve(frames[index],cal) if method=='current' else
                                solve_resampled(frames[index],s,repaired,method=method,
                                                distance_scale=.5,window_start=40))
                        row=dict(frame_id=int(frame_ids[index]),step_um=float(pos),source=source_name,
                                 method=method,distance_um=result['distance'],peak=result['peak_bin'],
                                 width=result['band_right']-result['band_left']+1,error='')
                        if method!='current':
                            row['coarse_integer_um']=result['coarse_integer']
                            row['coarse_parabolic_um']=result['coarse_parabolic']
                            row['coarse_log_um']=result['coarse_log']
                        else:
                            row['coarse_integer_um']=row['coarse_parabolic_um']=row['coarse_log_um']=float('nan')
                    except ValueError as error:
                        row=dict(frame_id=int(frame_ids[index]),step_um=float(pos),source=source_name,
                                 method=method,distance_um=float('nan'),peak=0,width=0,error=str(error),
                                 coarse_integer_um=float('nan'),coarse_parabolic_um=float('nan'),coarse_log_um=float('nan'))
                    row['elapsed_us']=(time.perf_counter()-started)*1e6
                    rows.append(row)
            print(f'{source_name} position {pos:g} um: {len(selected)} frames',flush=True)
    groups=[]
    for source_name in sources:
        for method in ('current','linear','cubic'):
            subset=[r for r in rows if r['source']==source_name and r['method']==method]
            zero=[r['distance_um'] for r in subset if r['step_um']==0 and np.isfinite(r['distance_um'])]
            anchor=float(np.mean(zero)) if zero else float('nan')
            error_values=[];positions=[]
            for pos in np.unique(truth):
                at=[r for r in subset if r['step_um']==pos]
                valid=[r for r in at if np.isfinite(r['distance_um'])]
                distance=np.asarray([r['distance_um'] for r in valid])
                displacements=anchor-distance
                errors=displacements-pos;error_values.extend(errors)
                coarse={}
                for key in ('integer','parabolic','log'):
                    coarse_anchor=np.mean([r['coarse_'+key+'_um'] for r in subset if r['step_um']==0])
                    estimates=np.asarray([r['coarse_'+key+'_um'] for r in valid])
                    coarse[key]=(float(np.mean(coarse_anchor-estimates)-pos) if method!='current' else None)
                positions.append(dict(step_um=float(pos),frames=len(at),valid=len(valid),
                    mean_displacement_um=float(np.mean(displacements)) if len(valid) else None,
                    bias_um=float(np.mean(errors)) if len(valid) else None,
                    std_um=float(np.std(distance,ddof=1)) if len(valid)>1 else None,
                    median_peak=float(np.median([r['peak'] for r in valid])) if valid else None,
                    median_width=float(np.median([r['width'] for r in valid])) if valid else None,
                    coarse_bias_um=coarse))
            groups.append(dict(source=source_name,method=method,zero_distance_um=anchor,
                p95_abs_error_um=float(np.percentile(np.abs(error_values),95)),
                worst_std_um=max(p['std_um'] for p in positions if p['std_um'] is not None),
                max_abs_position_bias_um=max(abs(p['bias_um']) for p in positions if p['bias_um'] is not None),
                invalid_rate=float(np.mean([not np.isfinite(r['distance_um']) for r in subset])),
                mean_elapsed_us=float(np.mean([r['elapsed_us'] for r in subset])),positions=positions))
    metadata=dict(k_units='rad/um',window_start=40,distance_scale=.5,
                  displacement_definition='D_at_zero - D_at_position; global sign only, no scale fit',
                  K_repair='None: supplied K strictly increasing' if np.array_equal(repaired,k) else 'Diagnostic isotonic first-edge repair; baseline uses original central K',
                  K_provenance=k_provenance,
                  K_modified_points=int(np.count_nonzero(repaired!=k)),
                  K_max_change=float(np.max(np.abs(repaired-k))),
                  rejected_discontinuity_samples=0 if include_discontinuity else int(np.count_nonzero(flags & DISCONTINUITY)),
                  discontinuity_policy='Included in static statistics per user W/T confirmation; not accepted as continuous throughput proof' if include_discontinuity else 'Excluded',
                  physical_gate_passed=False,groups=groups)
    with (output/'per_frame.csv').open('w',newline='',encoding='utf-8-sig') as stream:
        writer=csv.DictWriter(stream,fieldnames=rows[0].keys());writer.writeheader();writer.writerows(rows)
    (output/'summary.json').write_text(json.dumps(metadata,ensure_ascii=False,indent=2),encoding='utf-8')
    text=['# 11位置离线诊断A/B（μm）','','K端点修正只用于敏感性分析；未上传FPGA，不能自动批准部署。',
          '位移=零点绝对距离−当前位置绝对距离，只使用一个零点，不拟合距离比例。','',
          '|参考S|算法|P95绝对误差|最差标准差|最大位置偏差|无效率|', '|---|---|---:|---:|---:|---:|']
    for group in groups:
        text.append(f'|{group["source"]}|{group["method"]}|{group["p95_abs_error_um"]:.6g}|{group["worst_std_um"]:.6g}|{group["max_abs_position_bias_um"]:.6g}|{group["invalid_rate"]:.4g}|')
    (output/'report.md').write_text('\n'.join(text)+'\n',encoding='utf-8')
    print(json.dumps([{k:v for k,v in g.items() if k!='positions'} for g in groups],indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('samples',type=Path);parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--limit',type=int,default=1000)
    parser.add_argument('--include-discontinuity',action='store_true')
    parser.add_argument('--k',type=Path,help='Revised 1024-point K; strictly increasing, never repaired')
    args=parser.parse_args();run(args.samples,args.output,args.limit,args.include_discontinuity,args.k)
