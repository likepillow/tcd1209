# 前端 ILA/VIO 诊断工程

本工程用于实板前端有限帧观测，不是最终连续光谱测距系统。使用 50 MHz 板载时钟、实际 MMCM 产生 100 MHz 系统时钟，以及初始 5 MHz CCD 波形。未实例化 USB 引脚、距离处理器或主机数据发送器，因此不能用本工程宣称 USB 连续传输或实时测距已完成。完整目标仍包括更高速采集、每帧解算、USB 双向标定和在线显示保存。

## 工程及构建边界

顶层为 `rtl/diagnostic_top.v`，板级约束为 `constraints/diagnostic.xdc`，独立生成脚本为 `scripts/build_diagnostic.tcl`。脚本生成实际 ILA 6.2、VIO 3.0 IP，综合并运行至 route_design；不生成 bit 文件，不连接 JTAG，不写 FPGA 或 Flash。若项目已存在则拒绝覆盖。成功输出在 `build/diag`，保留报告与 LTX 调试探针文件。

初次 `build/diagnostic` 构建已终止：Vivado 2018.3 不接受 XDC 中的 foreach，且 debug hub 临时路径 148 字符超过该工具允许的 146 字符。约束已改为逐引脚显式语句，后续目录缩短为 `build/diag`。旧失败目录保留作诊断证据，不视为可用产物。

管脚采用 P3→P7 同号线对应的 25 个信号，加上 Y18 时钟与 B21 低有效复位。输出为 LVCMOS33、8 mA、SLOW；这些是起始驱动设置，不证明经过电平转换后模拟阈值或边沿已合格。外部 ADC 延迟和输出时序尚待实测，XDC 不编造延迟、不用宽泛 false path 隐藏未验证路径。内部实现时序通过也不能替代外部 IO 时序签核。

## 默认状态及控制

VIO probe_out0 为 run，初值 0；probe_out1 为 hold_reset，初值 1。上电保持前端复位；此时引脚固定为 φ1=1、φ2/SH/RS/CP=0，SHP/SHD/CLPOB/PBLK/SL=1，DATACLK/SCK/SDATA=0。MMCM 与调试时钟继续运行，使调试接口能够释放复位。

释放 hold_reset 后，等待四个系统时钟再释放前端复位，随后执行 AD9945 的上电等待与配置。configured 仅表示串行配置已发送，不是芯片读回确认。run 仍为 0 时，仅 AFE 配置和时钟运行，不启动 CCD 帧；run=1 才请求连续采集。

正常停止使用 run=0，允许当前帧完成。hold_reset=1 或板上复位按钮会中断帧，并立即钳位输出，即使 MMCM 停钟也有效；这可能截短当前脉冲，不能当作正常帧结束。复位后重新开始的首帧曝光时间未知，诊断可保留观察，但不能未经甄别就用于距离或光源标定。

## 探针映射

ILA 深度 8192、采样时钟 100 MHz、启用存储条件功能。

| 探针 | 宽度 | 内容 |
|---|---:|---|
| probe0 | 12 | 对齐后的 ADC 像素 |
| probe1 | 11 | 原始 2048 有效像素下标 0..2047 |
| probe2 | 32 | 帧号 |
| probe3 | 16 | 状态，见下表；也接 VIO probe_in0 |
| probe4 | 13 | 实际顶层输出逻辑值，位 12..0 为 φ1、φ2、SH、RS、CP、SHP、SHD、DATACLK、CLPOB、PBLK、SCK、SDATA、SL |
| probe5 | 12 | ADC 并行输入总线；非 valid 时可能正在翻转，仅用于诊断 |
| probe6 | 64 | 最近 SH 起始硬件时间戳，单位 10 ns；不是主机时间 |

| 状态位 | 含义 |
|---|---|
| 15..12 | 保留 0 |
| 11 / 10 | hold_reset / run |
| 9 / 8 | board_reset_n / MMCM locked |
| 7 / 6 | frontend_reset_n / configured |
| 5 / 4 | busy / alignment fault |
| 3 / 2 | frame_start / valid |
| 1 / 0 | first / last |

要捕获完整 2048 点帧，应将存储条件设置为 probe3[2]=1；仅“启用存储条件功能”并不会自动设置该条件。8192 个有效点最多覆盖四个完整帧，必须在 first 边界触发并检查 index/frame_id。若不设存储条件，8192 点仅覆盖 81.92 µs，不能覆盖 422.8 µs 的完整帧，但可观察短时间数字时序。ILA 采到的逻辑电平不能证明传感器端的 5 V 阈值、模拟建立时间或 ADC 采样窗口。

## 验证

`scripts/test_diagnostic.ps1` 已通过：使用实际 Xilinx MMCM/IBUF/BUFG 仿真，验证默认保持复位、未 run 不采集、ADC 数据接线、VIO 中止、按钮复位停钟时的引脚钳位与重新锁定。仿真中 VIO/ILA 为功能替代模型，不能证明调试核内部行为；实际调试 IP 由独立 Vivado 构建验证。传感器/AFE 引脚驱动模型和多帧对齐另由 `scripts/test_frontend.ps1` 覆盖。

2026-09-12，`build/diag` 的实际 Vivado 2018.3 运行已结束，退出码 0，设计状态 Fully Routed。资源为 2441 LUT、3919 寄存器、36 RAMB36、0 DSP、27 个固定 IOB。实现 IO 报告逐项确认前端 25 个信号和 B21 为 Bank16，Y18 为 Bank14，均为 LVCMOS33；同时已将 XDC 的前端 25 项与 p3_gpio0.csv 逐项比较一致。

已约束路径 WNS=+3.606 ns、WHS=+0.055 ns、TNS/THS=0；4 条 debug hub 总线偏斜约束均 MET，最小余量 +9.065 ns。check_timing 中无未约束内部端点、无缺失时钟、无组合环；仍有 13 个输入和 12 个输出缺少 IO 延迟，属于尚未完成的外部时序约束，不能用内部余量替代。

DRC 共 14 条 Warning、无 Error：CFGBVS-1 一条（尚缺配置 Bank0 的 CFGBVS/CONFIG_VOLTAGE 属性，必须依据板级供电核对后补齐，不从 Bank16 的 3.3 V 推断）；IOSR-1 十二条（ADC 同时接采集与原始 ILA 探针、复位不同，影响 IOB 寄存器打包）；RTSTAT-10 一条（调试核内部未使用负载网络）。不得通过降级规则或虚假约束把上述状态写成完全通过。下一步完成配置电压核对及诊断下载前检查，再生成专用诊断位流；实际 ADC 捕获窗口仍须测量。

报告在 `build/diag/{utilization,timing_summary,check_timing,drc,io}.rpt`；偏斜报告在 `build/diag/diagnostic.runs/impl_1/diagnostic_top_bus_skew_routed.rpt`，LTX 为 `build/diag/diagnostic.ltx`。未生成或下载位流，尚无该顶层的实板采集证据。

## 后续更新：位流生成与实板保持复位

2026-09-12 已依据原理图第 2、3 页补齐 CFGBVS=VCCO、CONFIG_VOLTAGE=3.3，并设置未使用 IO 弱上拉，详见 board_connections.md。`scripts/prepare_diagnostic_bitstream.tcl` 从已布线检查点生成独立 diagnostic_ready.dcp/diagnostic.bit，未重排逻辑。它检查目标器件、实际端口、调试核、IO 标准、内部建立/保持路径和严重 DRC，不禁用 DRC 规则。Vivado 2018.3 的独立检查点并不保留源文件集 TOP；此前两次基于名称的检查已失败退出，修正为验证实际网表端口/核后成功生成。

prebit_drc.rpt 现为 13 条 Warning（IOSR-1 十二条、RTSTAT-10 一条），0 Error、0 Critical Warning，CFGBVS-1 已消除。内部 WNS/WHS 及外部 IO 未约束的边界不变。位流 SHA-256：`4D33F7911E415EB0776AE5767179C029EA353E038358DE5CD5B36E364C76163E`。

经授权，`scripts/program_diagnostic.tcl` 已通过 JTAG 将 `build/diag/diagnostic.bit` 下载到唯一连接的 xc7a200t；只改易失配置，未写 Flash、未改 USB 固件。启动状态 HIGH，实板识别 ILA=1、VIO=1。VIO 读回：hold_reset 输出=1、run 输出=0；输入 locked=1、board_reset_n=1、release_pipe=0、configured=0、busy=0、fault=0、valid=0。configured=0 是保持复位的预期状态，不是 AD9945 配置失败。

当前实板停在保持复位状态，没有启动 CCD 采集。此轮证明了诊断位流可下载、MMCM 锁定、调试核可访问和默认控制值；尚不证明真实像素、模拟时序、USB 流或距离解算正确。下载记录在 build/diag_program.log。下一步可先释放前端复位但保持 run=0 检查 AFE 启动，再进行有限帧 ILA 和模拟测点对照。

## 后续更新：AFE 启动与首次有限帧捕获

2026-09-12 23:39，check_afe_startup.tcl 实板测试通过：run=0，释放 hold_reset 后 configured=1、release_pipe=1、busy/fault/valid=0；恢复 hold_reset 后 configured/release_pipe=0。该状态仅证明 FPGA 初始化状态机发完序列，不是 AD9945 寄存器读回或模拟功能确认。记录：build/afe_startup_hw.log。

23:50:55 首次 ILA 有效像素捕获成功。存储条件 valid_1=1，触发条件 first_1=1 且 valid_1=1，触发位置 0、8192 点、一个窗口。Vivado 2018.3 此实例的 CONTROL.TRIGGER_MODE 为只读 BASIC_ONLY；首次尝试在写此属性时停止，未启动 CCD，且恢复复位；修正为只读检查后第二次成功。等待上限 0.05 分钟（3 秒），捕获完成后先 run=0，等待 2 ms 完帧，再 hold_reset=1，随后上传 ILA 数据。停止时 busy=0/fault=0，最终读回 run=0/hold_reset=1。没有 USB 数据传输、重烧位流或 Flash 写入。

`build/hardware_frames/first_capture.csv` 经 `sim/check_hardware_capture.py` 检查：8192 个样本组成帧号 0、1、2、3，每帧下标严格 0..2047，first/last/valid、配置及复位状态均符合预期；SH 时间戳分别为 3398360、3440640、3482920、3525200 个 10 ns tick，帧周期 422.8 µs。这里只验证 FPGA 数字标记，不能单独证明它们对应正确 CCD 像素。

**全部 8192 个对齐 ADC 值及同拍原始输入总线值均为 0。** 因此尚无有效光谱；不执行 S 标定、不将其送入距离求解，也不把全零解释为已确认的遮光结果。可能涉及子板供电、ADC 输入/控制/配置、电平或连接、采样窗口等，原因尚未确定。下一步先核实 CCD/AD9945 子板实际供电，并在可用示波器条件下核对关键数字时钟和模拟输出。首帧曝光未知的限制仍适用。

数值概要：build/hardware_frames/first_capture_summary.json；原始操作日志：build/capture_first2.log。验证器新增全零不等同光学有效、索引错误、fault、帧周期错误四项测试，连同既有主机测试共 34 项通过。当前实板已恢复保持复位。

## 2026-09-20：更换 B 板和 CCD 后复测

用户报告新 B 板及 CCD 已在其他驱动板验证可采集，并接回 P7。首次只读检查未发现诊断核，随后经授权重新下载上述相同 SHA-256 的诊断位流，仅改易失配置，没有写 Flash 或 USB 固件。`scripts/test_replacement_hardware.ps1` 完成 SH 连续采样和四帧像素捕获，退出码 0。每次结束均检查 busy=0、fault=0，并读回 run=0、hold_reset=1；板卡最终保持复位，不在持续采集。

13:05:58 的 `replacement_20260920_sh.csv` 为 100 MHz、不抽取的 8192 点逻辑捕获，覆盖 81.92 µs。SH 在样本 1024 上升、1184 下降，高电平 1.600 µs，与 frame_start 同拍上升；SH 期间 RS/CP 均低。DATACLK 周期 200 ns（5 MHz）、高电平 100 ns；读出段 RS/CP 高电平各 30 ns、周期各 200 ns。phi1/phi2 无互补错误，fault 无置位。此短窗口只包含一个 SH 脉冲，不能直接测量相邻 SH 周期。分析器及结果：`sim/check_sh_capture.py`、`build/hardware_frames/replacement_20260920_sh_summary.json`。

上述测量对象是 FPGA 内部驱动输出缓冲器的数字网络，不是物理引脚反馈。结果符合当前诊断 RTL，但不能排除 P7 排线、电平转换、负载或 CCD 引脚处的幅度、边沿、脉冲异常；实际引脚仍须示波器确认。

13:06:02 的 `replacement_20260920_pixels.csv` 含连续 4 帧，每帧 2048 点，下标、帧号和边界检查通过，数字帧时间戳间隔 422.8 µs。首帧范围 0..4095，均值 3677.044，75 点为零、1284 点满量程；首帧曝光历史未知。后三帧所有点均为 4095，对应原始 ADC 输入也全部为 4095。与旧硬件的全零结果不同，但当前仍没有光学有效的未削顶帧，不能宣布正常光谱采集或做 S 标定/距离解算。光照状态尚未确认，不能仅凭满量程判定为过曝；下一步做完全遮光与弱光对照，必要时测 CCD 输出、AFE 输入及 SH/采样时序。

像素概要：`build/hardware_frames/replacement_20260920_pixels_summary.json`；操作日志：`build/replacement_program.log`、`build/replacement_sh.log`、`build/replacement_pixels.log`。此次通过 JTAG/ILA 捕获，不是 J5 USB 流测试。

### 同日 13:22–13:23：用户确认完全遮光后的启动与延迟对照

第一组 `dark_20260920_pixels.csv` 仍捕获启动帧 0..3：均值分别为 2943.256、4087.922、4095、4095，其中后两帧全部饱和。不能把这四个启动帧直接当作稳定暗场。

为检验启动瞬态，捕获脚本新增可选 0..100 ms settling 参数；非零时先 run，再等待指定时间，随后在下一个完整帧边界触发，保持原有停止及恢复复位流程。第二组 `dark_settled_20260920_pixels.csv` 设置 100 ms，实际捕获帧号 253..256。四帧结构检查全部通过，2048 点/帧、间隔 422.8 µs；均值分别为 123.363、124.105、124.402、123.952，整体范围 93..159，8192 点无零值、无满量程值，原始 ADC 输入亦非固定值。

这说明在本次遮光条件下，连续运行约 100 ms 后能取得稳定、未削顶的低电平暗场数据，早先启动四帧饱和不能作为稳态故障证据。现象与启动/模拟前端收敛过程相符，但仅凭这些样本不能确定具体机制或最短稳定时间，也不能证明光响应、像素空间对应或物理 SH 电气质量。下一步需在同样延迟捕获条件下做弱光及局部遮挡对照，再决定生产采集的启动帧丢弃策略。

两次测试均正常恢复 run=0、hold_reset=1，未重烧位流、未写 Flash 或 USB 固件。结果概要为同目录各 CSV 对应的 `_summary.json`；延迟捕获验证器通用的 first-frame exposure 提示不表示本次从帧 0 触发，应以实际帧号 253..256 为准。

### 同日 13:26：弱光半遮挡对照

用户确认弱光半遮挡后，以相同 100 ms 延迟条件捕获 `halfshade_settled_20260920_pixels.csv`。帧号 256..259，每帧 2048 点，帧边界及编号检查通过，周期 422.8 µs。全部 8192 点范围 76..330，无零值或满量程值；四帧均值依次为 208.878、209.809、211.226、209.727。

每 256 点分段，四帧平均后的八段均值约为 295.19、296.44、294.92、266.21、154.13、127.02、123.23、122.13。减去先前相同位置暗场均值后，八段增量分别为 170.57、172.60、171.89、142.34、30.98、4.36、-1.21、-3.89 ADC 计数。说明低下标区域有清晰光响应、高下标区域接近暗场，过渡区位于中部，符合半遮挡的空间特征。相邻帧逐像素 RMS 差值为 12.64、12.38、12.09 计数；四帧不足以评价长期稳定性或测距噪声。

这次取得了未削顶、有空间明暗差异且连续帧结构正确的 CCD 数据，不再支持“稳定全零/全满量程”的故障描述。数字 SH 之前已核对，但实际引脚电气波形、精确像素对齐、最高速率及 J5 USB 流仍未由该测试验证。进一步可保持光照、交换遮挡位置确认明暗分布随遮挡移动，而不是固定空间偏差。

操作记录 `build/halfshade_settled_20260920.log`：busy=0、fault=0，最终 run=0、hold_reset=1，退出码 0。未重烧位流、未写 Flash 或 USB 固件。概要为 `build/hardware_frames/halfshade_settled_20260920_pixels_summary.json`。

### 同日 13:31：反向半遮挡确认空间光响应

用户确认反向遮挡后，仍以 100 ms 延迟捕获四帧，文件 `reverse_halfshade_settled_20260920_pixels.csv`。帧号 254..257、2048 点/帧、帧间隔 422.8 µs，结构检查通过。四帧均值分别为 492.562、492.774、494.419、491.461；全部样本范围 98..1472，无零值或满量程值。

前次半遮挡低下标区域 0..767 均值 295.518、高下标区域 1280..2047 均值 124.127；反向后分别为 129.557、1041.789。明暗区域随遮挡交换，原亮区回到接近暗场的水平，原暗区出现明显光响应。反向后的八个 256 点区段相对暗场增量依次为 1.91、4.37、10.90、21.79、159.58、827.92、1022.69、901.64 计数。相邻帧逐像素 RMS 差值为 14.26、14.98、13.68 计数。

由此确认当前 5 MHz 诊断条件下具备连续帧结构和随遮挡位置变化的实际空间光响应，而非固定明暗偏置。两次亮区幅度显著不同，不能据此宣称照明等强、左右响应一致或已验证线性度。仍未直接测量 CCD 端 SH 电气波形，未验证最高速率、长时间稳定性、精确像素对齐、J5 USB 或测距性能。

本次测试退出码 0，停止时 busy=0、fault=0，最终恢复 run=0、hold_reset=1。未重烧位流、未写 Flash 或 USB 固件。日志为 `build/reverse_halfshade_settled_20260920.log`，概要为捕获同目录的 `reverse_halfshade_settled_20260920_pixels_summary.json`。
