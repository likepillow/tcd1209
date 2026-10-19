"""Generate the reviewable real-data decision and operating calibration files."""
import csv
import json
from pathlib import Path

import numpy as np

from workbench import LocalCalibration
from position_ab_experiment import smooth_source


def main():
    root=Path(__file__).resolve().parents[1]/'build'/'positions_20261003'
    summary=json.loads((root/'ab_confirmed_wt'/'summary.json').read_text(encoding='utf-8'))
    rows=list(csv.DictReader((root/'ab_confirmed_wt'/'per_frame.csv').open(encoding='utf-8-sig')))
    coarse=[];splits=[]
    for method in ('linear','cubic'):
        at=[r for r in rows if r['source']=='original' and r['method']==method]
        for kind in ('integer','parabolic','log'):
            key='coarse_'+kind+'_um'
            zero=np.mean([float(r[key]) for r in at if float(r['step_um'])==0])
            errors=np.array([zero-float(r[key])-float(r['step_um']) for r in at])
            coarse.append(dict(method=method,fit=kind,p95_abs_error_um=float(np.percentile(np.abs(errors),95))))
    for source in ('original','box31','box101'):
        for half in (0,1):
            at=[]
            for pos in range(0,51,5):
                group=sorted([r for r in rows if r['source']==source and r['method']=='current' and float(r['step_um'])==pos],
                             key=lambda r:int(r['frame_id']))
                cut=len(group)//2
                at.extend(group[:cut] if half==0 else group[cut:])
            zero=np.mean([float(r['distance_um']) for r in at if float(r['step_um'])==0])
            errors=np.array([zero-float(r['distance_um'])-float(r['step_um']) for r in at])
            splits.append(dict(source=source,half='earlier' if half==0 else 'later',
                               p95_abs_error_um=float(np.percentile(np.abs(errors),95))))
    decision={'uniform_k_resampling_gate':'FAIL: neither P95 nor worst repetition improved 20%, no invalid-frame failure eliminated',
              'recommended_chain':'existing phase-versus-measured-K chain; evaluate smoothing source S only',
              'source_smoothing_status':'box31 candidate, about 37.6% P95 improvement on this data; not an independent validation',
              'coarse_peak_results':coarse,'temporal_split_checks':splits,
              'K_endpoint_status':'20 points projected diagnostically, max change 2.2315e-5 rad/um; production fitting uses original central 512 values',
              'physical_distance_rate_gate':'PENDING: measured packet cadence passes, current ADC all-4095 saturation fails optical qualification',
              'flash_modified':False}
    (root/'decision.json').write_text(json.dumps(decision,ensure_ascii=False,indent=2),encoding='utf-8')
    with np.load(root/'samples.npz') as data:k=data['k'];source=data['source']
    target=root/'calibration';target.mkdir(exist_ok=True)
    np.savetxt(target/'K_fit512_original.txt',k[256:768],fmt='%.12g',
               header='original K[256:768]; W=40; effective pixels 296..807; rad/um; no K correction')
    np.savetxt(target/'S_box31_candidate.txt',smooth_source(source,31),fmt='%.12g',
               header='candidate only: 31-point reflected moving average of S, not of measurement S0')
    cal=LocalCalibration(window_start=40,period_pixels=3000,scale=.5,k_units='rad/um')
    cal.set_source(source,'user S.txt 2026-10-03, original')
    cal.set_k(k[256:768],'original central 512 of measured K.txt; no endpoint correction')
    cal.save(target/'original_S_K_fit512.npz')
    report=['# 2026-10-03 11位置实测评估','',
        'K单位rad/μm，W=40（零基），T=600μs，双程几何距离比例0.5。',
        '每个位置随机抽样1000帧，所有算法用相同帧；按用户确认不连续标志不影响静止统计。',
        '基准拟合保留原始中间512点K；重采样的端点等序修正仅用于敏感性分析。',
        '位移统一定义为零点距离减当前位置距离，仅用一个零点，不拟合距离比例。','',
        '## 算法比较（μm）','','|参考S|算法|P95绝对误差|最差重复性标准差|最大位置平均偏差|',
        '|---|---|---:|---:|---:|']
    for g in summary['groups']:
        report.append(f'|{g["source"]}|{g["method"]}|{g["p95_abs_error_um"]:.4f}|{g["worst_std_um"]:.4f}|{g["max_abs_position_bias_um"]:.4f}|')
    report += ['', '均匀K重采样未通过20%改善门限，本批数据不支持将其加入当前FPGA主链。',
        '只对参考S作31点平均改善约37.6%，是需复测的候选；101点并非更好，因此不宜一味增加平滑宽度。',
        '## 原始S当前相位法逐位置结果','','|已知步进|测得平均位移|偏差|标准差|','|---:|---:|---:|---:|']
    for p in summary['groups'][0]['positions']:
        report.append(f'|{p["step_um"]:.0f}|{p["mean_displacement_um"]:.4f}|{p["bias_um"]:.4f}|{p["std_um"]:.4f}|')
    report += ['', '## 寄生干涉和粗测距','',
        '主峰随步进由约13 bin移向9 bin，支持将其识别为待测峰。参考S还有98/101 bin等高频结构；',
        '原始S相除可能将其耦合到归一化谱，平滑S改变了偏差，支持后续重新采集无干涉光源参考。',
        '上述是频谱观察和敏感性分析，不能证明全部寄生路径已识别或已消除。','',
        '|重采样|粗峰拟合|P95位移误差（μm）|','|---|---|---:|']
    for g in coarse:report.append(f'|{g["method"]}|{g["fit"]}|{g["p95_abs_error_um"]:.4f}|')
    report += ['', '粗峰精度不足以替代相位法；目前也不能直接采用其未经标定的粗细差值剔除门限。',
        '## 数据质量和速率','',
        '记录192569个RAW帧，USB序号无缺包、CRC无错误、RESULT为0，distance.csv只有表头。',
        '帧号1076527..1276701范围包含200175个帧机会，缺少7606个RAW帧，约3.80%；',
        '这与USB已接收包的完整性是不同概念。标志对静止位置统计可按用户说明忽略，不能据此宣称无丢帧。',
        '实机5000个RESULT帧连续，时间戳间隔60000 ticks（1666.67Hz），主机约1616Hz；',
        '但51个采样S0全4095，当前固化版并未将其标为无效距离，故只能证明数值处理/传输吞吐。',
        '软件参考对此输入也给出约8.620815μm，FPGA约8.620819μm，数值接近不代表有真实测量意义。',
        '硬件已确认STOP ACK。Flash未更新。有效光谱下≥1000Hz验收和饱和保护仍待完成。',
        '## 操作与下一步','',
        '现有上位机可读取calibration/original_S_K_fit512.npz，W=40、T=600μs、距离比例0.5。',
        '其中K为原文件中间512点，并未修改端点或拟合比例。导入只更新草稿，须发送S/K并收到ACK。',
        'S_box31_candidate.txt只供对照；正式参考优先重新采集无干涉S并作128帧逐像素平均。',
        '减弱当前光强，确保S0不出现0/4095饱和，之后进行有效信号速率复测。',
        '后续完善ADC饱和与低质量/多峰距离标志，避免将钳位后的包络峰误判为有效测距。']
    (root/'实测评估说明.md').write_text('\n'.join(report)+'\n',encoding='utf-8')
    print(json.dumps(decision,ensure_ascii=False,indent=2))


if __name__=='__main__':main()
