# P3 到 ACX720-V3 GPIO0 的条件映射

本表依据用户提供的 1-B 板原理图 P3、ACX720-V3 原理图 PDF 第 11 页 P7，以及管脚表 Sheet1 第 229..254 行逐针整理。前提为 **P3 第 n 脚连接 P7 第 n 脚**。2026-09-12 用户已明确确认实物为同号直通排线，Bank 16 的 VCCO 已设为 3.3 V；尚未独立测量通断、电压和模拟波形。机器可读表为 `constraints/p3_gpio0.csv`，不自动加载到原始工程。

| P3/P7 针号 | 1-B 网络 | FPGA 封装管脚 | 相对 FPGA 方向 |
|---|---|---|---|
| 13 | FPGA_Φ2 | C13 | 输出 |
| 15 | FPGA_RS | D14 | 输出 |
| 16 | FPGA_Φ1 | D15 | 输出 |
| 17 | FPGA_SH | C14 | 输出 |
| 18 | FPGA_CP | C15 | 输出 |
| 19 | AD_SHP | B15 | 输出 |
| 20 | AD_SHD | B16 | 输出 |
| 21 | AD_PBCLK（AD9945 PBLK） | D17 | 输出 |
| 22 | AD_CLPOB | C17 | 输出 |
| 23 | FPGA_D11 | E16 | 输入 |
| 24 | AD_DATACLK | D16 | 输出 |
| 25 | FPGA_D9 | B17 | 输入 |
| 26 | FPGA_D10 | B18 | 输入 |
| 27 | FPGA_D7 | C18 | 输入 |
| 28 | FPGA_D8 | C19 | 输入 |
| 31 | FPGA_D5 | F16 | 输入 |
| 32 | FPGA_D6 | E17 | 输入 |
| 33 | FPGA_D3 | D20 | 输入 |
| 34 | FPGA_D4 | C20 | 输入 |
| 35 | FPGA_D1 | E19 | 输入 |
| 36 | FPGA_D2 | D19 | 输入 |
| 37 | AD_SCK | F18 | 输出 |
| 38 | FPGA_D0 | E18 | 输入 |
| 39 | AD_SL | F19 | 输出 |
| 40 | AD_SDATA | F20 | 输出 |

P3 的 1..10、14、29 未连接。P3 第 11 脚为 VCC5V，第 12、30 脚为 GND；P7 第 29 脚为 VCC3V3，但 P3 对应脚没有连接。电源脚不是 FPGA 信号，不得生成 PACKAGE_PIN 约束。不要把第 14 脚当作 φ1，也不要把 D6 的 E17 抄写成 F17。

这些信号使用 Bank 16。管脚表明确其电压为可选，不能因表中出现 3.3 V 就认为实物已经选到 3.3 V。应用 LVCMOS33 约束之前必须确认开发板 Bank 16 的 VCCO 为 3.3 V，前端数字输入/输出电压兼容且两板共地。5 V 只通过设计中的供电/电平转换网络使用，不得直接施加到 FPGA IO。

`scripts/check_pins.tcl` 使用 Vivado 的实际 xc7a200tfbg484-2 数据库校验 25 个封装管脚均存在、无重复且为 Bank 16 用户 IO。该检查不验证 PCB 走线、排线方向、板卡修订、电压或模拟时序，也不输出可下载位流。

该脚本已运行通过，25 个信号均为目标封装的 Bank 16 用户 IO。为满足 Vivado 查询条件，脚本先对小型 ad9945_init 设计进行内存内综合，再查询封装数据库；未修改原始 Vivado 工程。

## 板载时钟和复位

系统时钟为 U2 的 50 MHz 有源晶振，经 R5（33 Ω）到 FPGA_GCLK1。原理图 PDF 第 1 页显示管脚 Y18，管脚分配表 Sheet1 第 2 行一致，电平 LVCMOS33。复位采用 S4，表中 Sheet1 第 27 行为 B21；原理图第 10 页显示按键上拉、按下接地，并经 U17 电平转换到 FPGA，故按下为低有效。B21 不在此前 25 个 P3 信号中，不与前端输出复用。

`rtl/board_clock_reset.v` 使用 IBUF、MMCME2_BASE 和 BUFG 将 50 MHz 转为 100 MHz；参数为输入周期 20 ns、反馈倍频 20、输入分频 1、输出分频 10。复位链在 S4 按下或 MMCM 失锁时异步清零，在锁定后 16 个系统时钟上升沿后释放，标记 ASYNC_REG 并禁止推断为 SRL。

`scripts/test_board_clock.ps1` 使用 Vivado 2018.3 的真实 unisims_ver MMCM 模型测试通过，检查 430 个 100 MHz 周期、16 周期释放、按键抖动与重新锁定。未使用理想的乘二时钟替身。随后含 MMCM 的诊断顶层已完成布局布线并下载，VIO 实板读回 locked=1、board_reset_n=1；这些结果仍不等于测量了晶振频率、输入抖动或 ADC 模拟采样窗口。

## 配置 Bank 0 电压

2026-09-12 完整查看 ACX720-V3-SCH.pdf 第 2、3 页：第 2 页 U1F 的 CFGBVS_0/U8 直接接 VCC3V3；第 3 页 U1I 的 VCCO_0/E12、T12 接 VCC3V3。故设置 CFGBVS=VCCO、CONFIG_VOLTAGE=3.3，不从可选的 Bank16 供电推断。该软件属性用于描述已有硬件连接，不会改变板卡供电。

诊断位流另设置 BITSTREAM.CONFIG.UNUSEDPIN=Pullup，未使用 IO 仍为输入，使用弱上拉避免将未实例化的 FX2 低有效控制线默认弱拉低；不代表这些 USB 引脚已纳入主动时序控制。最终 USB 顶层应明确驱动读写/片选/包结束的空闲态。

配置属性语义参考 [AMD UG899，Configuration Bank Voltage Select](https://docs.amd.com/r/en-US/ug899-vivado-io-clock-planning/Setting-the-Configuration-Bank-Voltage-Select-Pin)，并由本机 Vivado 2018.3 接受、读回及 bitgen DRC 实际验证。修正后 CFGBVS-1 告警消除。
