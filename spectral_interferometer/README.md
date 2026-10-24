# TCD1209 光谱干涉采集与解算

2026-10-24 D1主机开发：新增分卷记录、异步有界队列、检查点/恢复及局部读取，旧SPIF v1兼容；使用新版源码启动。83项主机验证通过，长时间实机验收尚待执行。使用、证据与回退见[D1开发交付](docs/D1长时间记录与局部读取.md)。固件及旧exe未改。

目标器件为 xc7a200tfbg484-2，开发工具为 Vivado 2018.3。

2026-10-24曝光/关灯版26102402已固化并全片读回通过，Master-SPI重载及整板断电后的免下载器USB采集/停止复测通过。新版上位机、200 μs曝光、独立输出间隔及SPIF/HDF5/CSV科研导出已完成，见[升级说明](docs/曝光关灯与科研导出升级.md)及[交付核对](docs/20261024升级交付核对.md)。

## 当前交付状态（2026-10-04）

修正版K复测：原始SPIF/S不变，9条链路使用同一11000帧；新版1024点K严格递增，未作修正。原始S下，重采样使最差标准差约减半（通过原OR门限的重复性分支），但P95误差从0.3136增至约0.450～0.452 μm。31点参考S平滑+不重采样相位法P95约0.1872 μm，为本批最低；按准确度优先推荐不部署重采样。新标定草稿及完整结果在build/positions_20261004_k_revision1，未上传硬件或改Flash。

算法选择已按用户最新决定锁定：保留复数主峰滤波/IFFT相位展开/真实K斜率拟合；本批线性及自然三次样条重采样均未通过收益门限，粗峰精度也不如相位法，因此不部署重采样或粗峰辅助链。参考S支持128帧平均及可撤销31点平滑候选，不默认平滑测量S0。最终证据及未覆盖事项见[交付核查](docs/最终交付核查.md)。

上位机收尾更新：62项主机回归通过，新增回放及安全关闭专项用例；修复旧记录manifest第零包W/T配置漏应用，viewer.exe已重新打包。FPGA固化版及Flash不变。

2026-10-04钳位保护版26100301已固化：写前16 MiB备份与原控制版逐字节一致，写后全片读回验证通过，Master-SPI重载确认新版。用户确认整板断电重启后，仅USB复测启停/S/K保持及5000个RESULT处理吞吐通过，主机约1616 Hz，结束STOP ACK确认；首轮静默读的驱动错误及重试记录保留在免下载器启动说明。ADC窗口内任一点0/4095会使该帧RESULT标为INVALID。真实干涉距离精度仍由用户验证，非钳位输入吞吐不等同于物理准确度。

2026-10-03更新：完成用户提供11位置（5μm步进）的离线A/B；原始S相位法P95约0.334μm，线性重采样约0.537μm，未通过20%改善门限；仅平滑参考S的31点候选约0.208μm。上位机新增可撤回的参考S平滑，56项主机回归通过。实机5000个连续RESULT的时间戳节奏1666.67Hz、主机接收约1616Hz；但当时ADC全部4095饱和，光学有效性验收不通过。固化版未修改。详见`build/positions_20261003/实测评估说明.md`。

已验证并固化的控制版支持S0窗口起点W与CCD帧/积分周期T配置，并实现上电默认停止、显式开始/排空停止、正常关闭STOP ACK，以及按100 MHz时间戳的可调速回放。W范围0～1024；T范围422.8～999.8 μs、步进0.2 μs。详见[操作说明书](docs/操作说明书.md)、[在线窗口与曝光](docs/在线窗口与曝光.md)及[免下载器启动说明](docs/免下载器启动.md)。

已固化位流为`build/clipping_deploy/instrument_clipping.bit`（USR_ACCESS `26100301`），上一控制版`build/control_deploy`及写前整片备份`build/clipping_flash_audit/flash_before_program.bin`保留作回退。已打包上位机为`build/viewer_dist/viewer.exe`。连接USB后保持停止，配置完成后必须点击“开始采集”。

主机44项测试、RUN控制RTL、动态W/T和完整处理链数值回归已通过；控制版布局布线WNS +1.307 ns、WHS +0.009 ns，DRC无Error/Critical Warning。USB双向标定、S0可配置输出间隔、连续记录、运行事件和实时回放均已实现。真实干涉光路调试及物理距离验证按约定由用户完成。

启动、标定、保存和故障处理请以[操作说明书](docs/操作说明书.md)为准。控制版不依赖VIO，也不需每次重新加载FPGA或FX2 RAM固件；日常连接USB只进入准备状态，不会自动采集。

## 历史开发记录（以下阶段状态不代表当前交付状态）

2026-10-02补充：上位机参考S逐像素多帧平均、离线线性/自然三次样条重采样A/B及SPIF数据集转换已实现；52项主机回归通过。实机256个S0帧无缺包和CRC错误，采集时间戳对应2365.18帧/秒，128帧平均完成、STOP ACK确认。固化FPGA仍为26092402。真实K/已知位移A/B门限尚待用户光学数据；预计约10.24μs的线性插值预算是架构估算，需RTL和布局布线后确认，不能作为新算法已满足1000Hz的实测证据。

最新实板状态：独立 ILA/VIO 诊断位流已下载，时钟锁定、采集保持复位（hold_reset=1/run=0），未写 Flash。配置电压属性已核对补齐；尚未捕获真实 CCD 帧、验证 USB 数据流或完成整机测距。下文早期阶段描述以 `docs/diagnostic_bringup.md` 的后续更新为准。

后续首次捕获：AFE 启动控制实板通过，ILA 得到四帧数字采样（8192 点），帧号/索引/周期检查通过，但 ADC 原始和对齐值均全零，尚无有效光谱；已停止并恢复保持复位。正在核查子板供电和输入链路，不能使用此次数据作光源标定。主机及捕获检查器测试现为 34 项通过。

## 已实现内容

- `host/reference.py`：2048 点中间裁剪 1024 点，光源归一化、去均值、正频主峰搜索、保留复数频谱、IFFT、相位解包裹与中间 512 点最小二乘斜率。支持 S/K 标定文件保存和读取。
- `host/resampling.py`、`host/ab_evaluate.py`：线性均匀K重采样、无SciPy的自然三次样条精度参考、三点亚频点粗峰和共同数据集A/B报告。当前仅为软件评估路径，不代表固化FPGA已启用重采样。
- `rtl/frame_ping_pong.v`：两组 1024×16 帧缓存，帧号随数据传递，输出握手，满缓存整帧丢弃计数，短帧和超长帧拒绝发布。
- `rtl/acquisition_core.v`：2048 点输入、中间 1024 点双缓冲与数值核心连接；独立 raw_* 接口供未标定时观察/采集光源参考，按完整缓存帧决定是否进入解算。
- `rtl/ad9945_init.v`：上电等待后写入启动、操作、控制、钳位及增益寄存器，串行位序、时序和复位恢复仿真通过；已接初始前端，尚未实板验证。
- `rtl/adc_pixel_align.v`：AD9945 十次转换标记延迟及延后并行捕获；8193 点对齐测试、4 帧中间 1024 点 Ping-Pong 裁剪联合仿真通过。接口及尚未验证的板级条件见 `docs/adc_capture_contract.md`。
- `rtl/ccd_afe_timing.v`、`rtl/ccd_frontend.v`：初始 5 MHz CCD/AFE 波形、初始化与 ADC 捕获连接；引脚驱动模型验证 5 帧 / 5120 个裁剪点，OOC 综合完成。非最终高速配置，尚未下载；详见 `docs/frontend_timing.md`。
- `rtl/board_clock_reset.v`：实际 MMCM 原语实现板载 50 MHz 到 100 MHz 与锁定后同步释放复位；仿真覆盖 430 个时钟周期、按键抖动及重锁定，已接诊断顶层。
- `rtl/diagnostic_top.v`：初始前端 ILA/VIO 诊断顶层；默认保持采集复位，控制与引脚钳位仿真通过，实际 IP 布局布线完成，已约束路径 WNS=+3.606 ns、WHS=+0.055 ns。配置电压属性和外部 IO 时序仍待补齐，未生成/下载位流。探针及验证边界见 `docs/diagnostic_bringup.md`。
- `rtl/normalize_frame.v`：倒数乘法归一化、整帧去均值、影子标定 RAM 和帧边界原子切换；两帧 2048 点的定点仿真比较通过。
- `rtl/spectral_transform.v`：按实际生成 XFFT 接口连接 FFT/IFFT，保留 IFFT 的 43 位实虚部。IP 创建脚本为 `scripts/generate_fft_ip.tcl`。实际 IP 两帧往返仿真通过，覆盖实部正脉冲、虚部负脉冲、缩放、索引、帧尾和输出背压。
- `rtl/positive_peak_filter.v`：正频率主峰及两侧谷底搜索，带内复数逐位保留，带外清零。5120 个频点的边界、极值、并列峰和背压测试通过，综合为 4 个 BRAM、8 个 DSP。
- `rtl/phase_cordic.v`、`rtl/phase_unwrap.v`：43 位复数 atan2 与 1024 点相位解包裹。6144 点独立数值验证通过，零幅值和恰好 π 跳变携带无效标记。
- `rtl/spectral_phase.v`：实际 FFT → 主峰复数滤波 → IFFT → CORDIC → 解包裹。四帧联合仿真通过，包括空帧后恢复，测试有效帧最大相位误差约 3.50×10⁻⁶ rad。
- `rtl/distance_fit.v`：中间 512 点的 84 位距离乘加、双银行 K 权重和指数原子切换、配置校验及结果背压；六帧逐位测试通过，综合为 2 个 BRAM、6 个 DSP。
- `rtl/spectral_processor.v`：归一化、FFT/复数滤波/IFFT、CORDIC/解包裹及距离拟合集成核心，同时导出 S0/S1/S2 光谱、相位和距离，三路独立握手。实际 IP 四帧联合测试通过，包括非整数条纹和空帧后恢复。
- `host/fixed.py`：S 倒数、归一化和 K 拟合权重定点契约；32 位整数拟合权重严格零和，84 位累加模型与拟合 RTL 逐位比较通过。
- `sim/test_reference.py` 与 `sim/tb_frame_ping_pong.sv`：算法解析解测试和 Vivado 帧流仿真。
- `docs/research.md`：硬件依据、算法定义、实现约束与待完成事项。
- `docs/numeric_contract.md`：定点格式、上传事务、变换缩放和验证范围。
- `docs/acquisition_contract.md`：2048 点裁剪发布规则、未标定原始流和 AD9945 初始化接口。
- `docs/board_connections.md`、`constraints/p3_gpio0.csv`：前端 25 个信号映射，通过目标封装核验；用户已确认 P3/P7 同号直连及 Bank 16 为 3.3 V，模拟波形仍待实测。
- `rtl/packet_tx.v` 与 `host/protocol.py`：SPIF v1 CRC 字节流协议，已接FX2 USB、采集多路输出、W/T、S/K、导出间隔和RUN_CONTROL命令。
- `host/recording.py`：原始包保存、距离 CSV、运行事件、完整性清单及回放后端；异常/缺包/无效距离不隐藏。
- `docs/protocol.md`：传输字段、标定 ACK 语义、带宽边界、保存和回放说明。
- `host/viewer.py`、`workbench.py`、`receiver.py`、`live_receiver.py`：Tk 上位机工作台，提供在线USB、显式采集启停、安全断开、S/K与W/T配置、参考S多帧逐像素平均、光谱/距离绘图、曲线导出和可调速回放。使用及验证边界见 `docs/host_workbench.md`。
- `docs/hardware_bringup.md`：JTAG 与独立 J5/FX2 联调记录；04B4:00F1、高速 EP2 OUT/EP6 IN、30 MHz FIFO及连续双向传输已验证。
- `scripts/inspect_usb.ps1`：Cypress 库属性及标准 GET_DESCRIPTOR 只读检查；不发送 bulk/vendor 命令、不复位或烧写设备。

## 运行参考解算

Python 依赖 NumPy。输入 txt 每行一个数值，允许空行及以 `#` 开头的注释。

```powershell
python host/reference.py frame.txt source.txt k.txt --output result.npz
python sim/test_reference.py
powershell -File scripts/test_buffer.ps1
powershell -File scripts/test_capture.ps1
powershell -File scripts/test_ad9945.ps1
powershell -File scripts/test_adc_align.ps1
powershell -File scripts/test_frontend.ps1
powershell -File scripts/test_board_clock.ps1
powershell -File scripts/test_diagnostic.ps1
powershell -File scripts/test_normalize.ps1
powershell -File scripts/test_peak.ps1
powershell -File scripts/test_phase.ps1
powershell -File scripts/test_fit.ps1
python sim/test_fixed_fit.py
powershell -File scripts/test_processor.ps1
powershell -File scripts/test_processor.ps1 -Capture
powershell -File scripts/test_packet.ps1
python sim/test_recording.py
python -m unittest discover -s sim -p "test_*.py"
python host/viewer.py
```

也可直接运行已打包的 `build/viewer_dist/viewer.exe`，无需另行安装 Python。重新打包时执行：

```powershell
& .\scripts\build_viewer.ps1 -Python python
```

frame/S 接受 2048 个有效像素或已经裁剪的 1024 点。K 接受 2048、1024 或最终拟合区间的 512 点。2048点S/K按当前W取W..W+1023；随后拟合取该窗口的256..767，因此对应原始有效像素W+256..W+767，均为零基下标。

默认 distance=slope，遵循指定算法。若 K=2π/λ、光路为双程且希望输出几何距离，应明确使用 `--distance-scale 0.5`。保留正索引 FFT 分量会影响相位斜率符号；K 降序时默认斜率为负，程序不偷偷取绝对值。

结果 NPZ 包含 S0/S1/S2/H0/H1/S3/P0/P1 以及斜率、距离、主峰及边界、拟合残差和饱和像素计数。它是软件参考结果，不能作为 FPGA 已完成解算的证据。

## 验证范围

参考模型测试通过 7 项。Vivado 2018.3 的默认 1024 点仿真通过，检查缓存所有权、完整帧边界、输出背压、丢帧、短帧和帧号。综合脚本 `scripts/synth_buffer.tcl` 已在 xc7a200tfbg484-2 上验证两组默认深度缓存推断为 2 个 BRAM 原语；综合不等于布局布线时序闭合。调用此脚本时通过 `-tclargs` 传入本目录绝对路径。

## 后续集成

FFT IP 首次创建及测试：调用 Vivado batch，依次执行 `scripts/generate_fft_ip.tcl` 与 `scripts/test_transform.tcl`，均通过 `-tclargs` 传入本目录绝对路径。生成和仿真输出位于 build/fft_ip，不写入原始 Vivado 工程。首次实际 IP 仿真展开约需数分钟。

完整相位链测试：在 FFT IP 已生成后，用相同方式运行 `scripts/test_spectral_phase.tcl`，随后运行 `python sim/check_spectral_phase.py build/fft_ip/spectral_fft.sim/sim_1/behav/xsim/spectral_phase_output.csv`。Tcl 检查协议断言，Python 检查数值，两者均通过才算测试完成。单独复数链使用 `test_analytic.tcl` 与 `check_analytic.py`。

完整数值核心使用 `test_processor.ps1`，串接向量生成、实际 IP 仿真及 Python 数值比较；缺少隔离 FFT 工程时先生成 IP。四帧包含整数条纹、72.35 周期非整数条纹、空帧及恢复；导出的 S0/S1/S2 和距离整数逐位一致，主峰边界与浮点模型一致，最大相位误差约 7.91×10⁻⁷ rad。该精度是对给定 ADC 合成向量的算法数值误差，不代表光学测距准确度。

`synth_processor.tcl` 已综合整个数值核心并链接实际 FFT/IFFT 网表，检查未解析模块数为零。资源为 23356 LUT、23469 寄存器、86 DSP、20.5 个 BRAM36 等效块；100 MHz 综合后内部 WNS=+1.778 ns。通过 Vivado batch 执行，`-tclargs` 指定本目录绝对路径。尚未进行板级布局布线和 IO 时序验证。

连续采集版本 `test_processor.ps1 -Capture` 同样通过全部数值比较，额外验证未标定原始帧、配置切换、12.5 MHz 输入及 170.02 μs 帧周期，四帧无丢帧。`synth_processor.tcl` 在目录参数后增加 `capture` 可综合 acquisition_core；该版本为 23492 LUT、23697 寄存器、86 DSP、21.5 个 BRAM36 等效块，100 MHz 综合 WNS=+1.778 ns。详见采集接口文档。

控制版已完成临时下载实机RUN启停/SK保持验收、Flash全片写前比对、烧写/Verify、读回比较和Master-SPI重启复测。真实干涉条纹和物理测距精度验证由用户完成。根目录原Vivado工程仍为参考来源。
# 2026-10-24曝光、关灯与科研导出升级

200 μs起曝光、独立距离输出间隔、关闭8个可控用户灯，以及SPIF→HDF5/CSV科研导出，见[升级说明](docs/曝光关灯与科研导出升级.md)。新位流26102402已备份后固化并全片校验通过；新版viewer_research_dist及整板断电启动已验证。原26100301位流/Flash备份和原viewer_dist保留。

