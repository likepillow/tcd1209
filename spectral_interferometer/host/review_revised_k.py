"""Review a same-frame K revision experiment without deploying its calibration."""
import argparse
import csv
import json
from pathlib import Path
import numpy as np
from position_ab_experiment import smooth_source
from workbench import LocalCalibration


def review(root, samples):
    root = Path(root)
    summary = json.loads((root/'summary.json').read_text('utf-8'))
    groups = summary['groups']
    with (root/'per_frame.csv').open(encoding='utf-8-sig',newline='') as stream:
        rows=list(csv.DictReader(stream))
    identities={}
    for row in rows:
        identities.setdefault((row['source'],row['method']),set()).add((row['step_um'],row['frame_id']))
    common=identities[('original','current')]
    if len(common)!=11000 or any(points!=common for points in identities.values()) or len(identities)!=9:
        raise ValueError('Expected identical 11000 frame identities in all nine chains')
    if any(p['frames']!=1000 for g in groups for p in g['positions']):
        raise ValueError('Expected 1000 shared frames per position')
    gates = []
    for source in ('original', 'box31', 'box101'):
        baseline = next(g for g in groups if g['source']==source and g['method']=='current')
        for method in ('linear', 'cubic'):
            candidate = next(g for g in groups if g['source']==source and g['method']==method)
            p95 = 1-candidate['p95_abs_error_um']/baseline['p95_abs_error_um']
            repeat = 1-candidate['worst_std_um']/baseline['worst_std_um']
            gates.append(dict(source=source,method=method,p95_improvement=p95,
                              worst_std_improvement=repeat,
                              original_or_gate_passed=bool(p95>=.2 or repeat>=.2)))
    best = min(groups, key=lambda g:g['p95_abs_error_um'])
    decision = dict(common_frame_identities=len(common),all_nine_chains_same_frames=True,
                    K_modified_points=summary['K_modified_points'],
                    K_provenance=summary['K_provenance'],
                    same_source_gate_comparisons=gates,
                    best_observed_p95_chain=dict(source=best['source'],method=best['method'],
                                                p95_abs_error_um=best['p95_abs_error_um']),
                    recommendation='retain current phase chain with optional box31 source; do not deploy resampling for P95 accuracy priority',
                    caveat='Original-S repetition-only gate passes; absolute P95 gets worse. This is not a blanket failure of the original OR gate. Box31 source candidate needs independent validation.',
                    hardware_modified=False)
    (root/'decision.json').write_text(json.dumps(decision,ensure_ascii=False,indent=2),'utf-8')
    with np.load(samples) as data:
        source = data['source']
    k = np.loadtxt(root/'K_revised_input.txt')
    target = root/'calibration'
    target.mkdir(exist_ok=True)
    np.savetxt(target/'K_fit512_revised.txt',k[256:768],fmt='%.12g',
               header='revised measured K, unchanged central 512; W=40; effective pixels 296..807; rad/um')
    for name in ('original', 'box31'):
        cal = LocalCalibration(window_start=40,period_pixels=3000,scale=.5,k_units='rad/um')
        cal.set_source(source, 'original user S; same as first experiment')
        if name=='box31':
            cal.smooth_source(31)
        cal.set_k(k[256:768], 'revised user K 2026-10-04; no K repair')
        cal.save(target/f'{name}_S_revised_K_fit512.npz')
    lines=['# 修正版K同帧复测（2026-10-04）','',
           '新版K严格递增，无自动修正；K单位rad/μm，W=40零基，T=600 μs，距离比例0.5。',
           '复用已核对的原记录共同11000帧，每处1000帧；原始SPIF及S文件未变。',
           '只用各链路一个零点，不拟合距离比例；转场帧排除，不连续按用户说明用于静止统计。','',
           '|参考S|方法|P95误差 μm|最差标准差 μm|最大位置偏差 μm|无效率|',
           '|---|---|---:|---:|---:|---:|']
    for g in groups:
        lines.append(f'|{g["source"]}|{g["method"]}|{g["p95_abs_error_um"]:.6f}|{g["worst_std_um"]:.6f}|{g["max_abs_position_bias_um"]:.6f}|{g["invalid_rate"]:.2%}|')
    lines += ['', '## 门限与建议','',
              '不能笼统称新版重采样“未通过原门限”：原始S的线性和样条最差标准差分别改善约51.1%和50.4%，因此原计划“P95或重复性改善20%”的OR门限在重复性分支通过。',
              '但原始S的P95从0.3136增加至0.4520/0.4505 μm，准确度变差；固定31点参考平滑后，重采样的P95和最差标准差均比不重采样差。',
              '按用户只保留最高精度方法的要求，以共同帧P95绝对误差优先，推荐不重采样相位法+可选31点参考S平滑（P95约0.1872 μm）。该结论只适用于本批数据，仍不能证明寄生路径已消除。',
              '本次没有上传K、下载位流或写Flash；输出NPZ为本地草稿，用户先应用W/T，再读取NPZ并发送S/K成功ACK后才在实机生效。',
              '自然三次样条的Python参考耗时不是FPGA耗时或1000 Hz硬件门限证据。','',
              '## 无示波器时的验证边界','',
              '可用ILA验证数字时序/帧标签，并比较不同捕获延迟的易失候选在暗场、弱光、遮挡条件下是否存在错位或不稳定；只能支持当前实物工作条件下的数字采集验证。',
              'ILA和普通逻辑分析仪不能证明CCD驱动电压、模拟边沿/交越、ADC全温度输出延迟或完整板级最坏情况时序。必要时借用示波器或由板卡供应商提供实测报告；不能用缺包为零替代这些电气证据。']
    (root/'修正版K复测说明.md').write_text('\n'.join(lines)+'\n','utf-8')
    rows=[dict(method={'current':'不重采样','linear':'线性插值','cubic':'自然三次样条'}[g['method']],
               source={'original':'原始S','box31':'S平滑31点','box101':'S平滑101点'}[g['source']],
               p95_um=g['p95_abs_error_um']) for g in groups]
    provenance=dict(label='11位置修正版K同帧离线复测',
                    files=[{'label':'K.txt（2026-10-04修订）'},{'label':'11处位置信号.spif'},{'label':'S.txt'}],
                    filters=['11处已知位置：0至50 μm，每5 μm步进','每处同样1000帧','W=40零基','距离比例0.5，单零点校正'],
                    caveats=['离线重算，不是新版FPGA实机测距验收。','31点参考平滑仅为本批候选，尚无独立光学复测。'])
    chart=dict(schemaVersion=1,id='revised-k-p95',title='修正版K：11位置P95位移误差（越低越好）',
               chart=dict(type='bar',x='method',y='p95_um',series='source',yLabel='P95绝对误差（μm）'),
               rows=rows,source=provenance)
    (root/'chart.json').write_text(json.dumps(chart,ensure_ascii=False,indent=2),'utf-8')
    receipt=dict(schemaVersion=1,items=[dict(id='revised-k-p95',title='修正版K下的相位测距误差比较',
                 queries=[dict(id='same-frame-k-ab',source=provenance,rows=rows,
                               columns=['method','source','p95_um'])])])
    (root/'sources.json').write_text(json.dumps(receipt,ensure_ascii=False,indent=2),'utf-8')
    print(json.dumps(decision,ensure_ascii=False,indent=2))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('experiment',type=Path)
    parser.add_argument('--samples',type=Path,required=True)
    args=parser.parse_args()
    review(args.experiment,args.samples)
