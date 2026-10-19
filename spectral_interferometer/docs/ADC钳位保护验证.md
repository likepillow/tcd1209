# ADC钳位保护（2026-10-04已固化26100301）

最新状态：按用户授权，26100301已写入Flash，写前整片备份、写后全片比对及Master-SPI重载验证通过。用户随后确认整板断电重启，仅USB复测启停和5000个结果处理吞吐通过，最后确认停止；首轮静默读有一次驱动错误，原记录保留，重试通过。下文保留候选阶段的历史验证记录；当前断电启动不再恢复26092402。部署、冷启动过程及备份详情见`免下载器启动.md`。

现有固化控制镜像26092402可能对全4095输入给出未标无效的数值距离。原因是非平坦参考S相除后会产生谱结构，FFT和相位运算可以完成，但这不是有效测量。

候选RTL在normalize_frame缓存整帧时检测所选1024点S0。任一点等于12位ADC下轨0或上轨4095，该帧整体标为INVALID；这是保守的测量质量规则，不是断言器件故障。只有窗口内像素参与判断，窗口外的遮光/饱和不影响结果。

保护不停止采集、不截断帧、不清除S/K、不丢弃RAW包。算法仍完成，RESULT沿用原协议的INVALID标志，数值不得作为有效距离使用。下一帧重新检测，因此健康帧自动恢复。数值溢出frame_overflow与光学钳位frame_clipped分开保存。

验证命令：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_clipping.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_normalize.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test_processor.ps1 -Packet -Clipping
```

第一项覆盖首像素、末像素、全4095、健康帧恢复与反压。第二项检查逐点归一化及配置兼容性。第三项使用实际FFT/IFFT IP，比较相位和定点距离，同时逐字节检查RESULT无效标志与CRC，以及健康帧恢复。

本文件描述候选版本，不代表非易失Flash已更新。有效光谱下至少1000 Hz的实机验收仍单独需要完成。

## 已执行结果

上述三项仿真均通过。完整采集/FFT/IFFT/相位/定点拟合仿真覆盖四帧：健康、末像素4095、无主峰、健康恢复。全部帧1024个相位点的INVALID状态正确，RESULT包逐字节及CRC比较通过，无采集丢帧。非无主峰帧相位与浮点参考最大差低于2.6e-7 rad；定点MAC与整数参考逐位一致。仿真日志为build/acquisition_packet_sim.log，数值输出位于build/fft_ip/spectral_fft.sim/sim_1/behav/xsim。56项主机回归也通过。

Vivado在受限环境中生成仿真脚本曾遇到路径错误；使用获准的沙箱外仿真重跑后通过，没有下载硬件或更新Flash。这些仿真不代替新位流的实现签核与实机验收。

## 候选实现与易失实机验证

已使用Vivado 2018.3完成综合、布局布线和候选位流生成，版本USR_ACCESS=26100301。位流为build/clipping_deploy/instrument_clipping.bit，SHA256=7B1ADC9B5680D0FF34C31CA44EDC8FBCC7F07F7D4CC5212CCB6BD1531C135412。原build/control_deploy及Flash26092402保留不变。

已约束路径WNS=+0.908 ns、WHS=+0.040 ns；FX2输出建立/保持裕量6.320/3.000 ns，输入建立/保持裕量14.504/0.599 ns，现有部署门限通过。位流DRC没有Error或Critical Warning，仍有DSP流水建议、BRAM异步控制等Warning。布局后资源LUT18.76%、寄存器10.13%、BRAM6.58%、DSP11.62%，各类保留超过50%余量。

验证边界：13个输入及15个输出仍缺外部I/O延时约束（CCD/AD9945及复位等），故不是完整板级生产签核；现有USB可行性约束也未包含实测PCB飞行时间。CDC报告继承控制版的复位网络CDC-10/CDC-11提示，不得称为零CDC告警。详细报告在build/clipping_implementation和build/clipping_deploy。

候选已通过JTAG易失下载并读回版本，日志build/clipping_volatile.log。随后明确执行钳位负向测试：build/positions_20261003/clipping_rejection/summary.json记录5000个连续RESULT，全部INVALID；50个RAW抽样帧全部4095；时间戳1666.67 Hz、主机包吞吐1616.03 Hz；包序号、CRC、设备丢帧/异常均为0，S/K版本一致，STOP ACK确认。负向保护门限通过；有效结果速率为0 Hz，光学有效性门限未通过。不能把包吞吐当成有效测距速率。

当前FPGA易失配置为26100301，W=40、T=600 μs、原始S及原始中间512点K已上传，采集已停止。整板断电后恢复Flash控制版26092402，后者尚无此次钳位保护。先调节光强或曝光并取得有效光谱，再验证有效距离结果速率；未通过前不更新Flash。

随后进行最短曝光RAW诊断：临时设置W=40、T=422.8 μs（不使用不匹配曝光的参考解算距离），32帧仍全部4095，CRC/包序号无异常。记录build/positions_20261003/min_exposure_probe/summary.json。已恢复W=40、T=600 μs、原始S/K、S0间隔100，配置ACK及STOP ACK均确认。该结果表明当前合法曝光范围内仅缩短T尚不足以恢复信号，但不能据此区分过强照明与模拟前端异常。下一步需要用户完全遮光作对照；没有这种光学状态变化时，不继续重复饱和采集或更新Flash。

## 2026-10-04用户降低光强后的复测

用户确认降低光强后，build/weak_light_20261004/summary.json记录256帧S0，ADC范围2120～2334、均值2242.71，无0/4095像素，CRC及包序号无异常，128帧平均完成；这次光照不自动作为正式无干涉参考S。随后使用本批原始S和原始中间512点K、W=40、T=600 μs运行距离数值处理，build/positions_20261004/weak_result_rate/summary.json记录5000个连续RESULT：硬件时间戳1666.67 Hz，主机1616.55 Hz，INVALID为0，50个RAW抽样均不钳位；CRC、包头、载荷、包序号、设备丢帧/异常均为0，S/K版本一致，结束STOP ACK确认。非钳位输入处理吞吐门限通过。

build/positions_20261004/jtag_identity.log只读确认运行版本26100301，未重新下载或写Flash。弱光下没有证明待测干涉条纹及参考光学条件匹配，因此约8.62398 μm的数值不能作为真实距离验证。报告中的optical_signal_qualified为兼容字段，仅指抽样RAW未钳位；rate_gate_passed仅是数值处理速率门限，不是物理准确度验收。真实干涉测距精度仍按用户约定自行验证。
