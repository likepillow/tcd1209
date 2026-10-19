# 实板联调记录与下一步

## 已确认的条件

2026-09-12 用户确认：P3→ACX720-V3 P7（GPIO0）为同号直通排线，Bank 16 VCCO 已设为 3.3 V，Vivado 2018.3 已连接 FPGA，并明确授权接管下载器进行本项目测试和分析。

用户进一步确认实物为 **板载 Xilinx-HS2 下载器款**；据用户说明，与此前规格的唯一区别是增加板载下载器，使用一根 Type-C USB 数据线即可同时供电、下载和调试。随后明确更正：下载器仅用于烧录调试，可以另接 J5 作为 USB 数据连接，不需要分析 HS2 数据通道。后续按 HS2/JTAG 与 J5/FX2 分离的方案推进；“可以连接”尚不等于已完成连接或成功枚举。

同日已执行 Vivado 只读 JTAG 检查，实际返回设备 `xc7a200t_0`、PART=`xc7a200t`。配置寄存器 DONE、EOS 为 1，CRC_ERROR、IDCODE_ERROR 为 0。当前位流没有支持的 ILA/VIO 调试核，不能仅凭 JTAG 已连通就读取内部采集 RAM。此次未下载任何新位流、未写 Flash、未修改原工程。JTAG 器件识别不独立证明封装和速度等级，工程目标仍依据实板型号信息采用 xc7a200tfbg484-2。

Windows 当前识别到 FTDI USB Serial Converter（VID 0403、PID 6014），Vivado 将其识别为 Digilent JTAG 目标。当前筛选未发现 Cypress/FX2 数据设备；这说明尚未建立数据端识别证据，不能只据此断定电路故障。

更新：2026-09-12 用户确认下载器和 J5 均已连接后，Windows 实际枚举到 `04B4:00F1`，设备名称为 `EZ-USB FX2 GPIF to Ext FIFO Example using Single Transactions`。该设备 Status=Error、ProblemCode=28，驱动 INF、版本和服务字段为空；FTDI 下载器仍为 OK。Microsoft 将 Code 28 定义为未安装驱动/未选定设备驱动，当前应先处理 J5 驱动，不按物理连接失败处理。设备名称只是描述符/枚举信息，不足以证明运行固件等同于某个源代码版本或具备所需 Slave FIFO 配置。

本地 `Downloads/05_驱动和常用软件/小软件/FX2_USB_工具.rar` 包含固件源码和驱动。已只读检查其中 Win8.1/x64 的 cyusb3.inf：2014-08-21，版本 1.2.3.10，明确包含 `USB\VID_04B4&PID_00F1` 的 x64 匹配项；该 INF 的 FX3 名称不能反推实物芯片型号。解出到独立 build/usb_driver_review 的 CAT、SYS 和 WDF DLL 的 Authenticode 状态均为 Valid；CAT/WDF 签名者为 Microsoft，SYS 签名者为 Cypress。系统为 Windows 10 22H2，Build 19045。此处签名验证不等于已成功安装或确认全部运行兼容性，不修改 INF 破坏目录签名，也不关闭签名强制、Secure Boot 或内存完整性。

经授权尝试 pnputil 添加并安装该 INF，系统返回 Access is denied，新增驱动包为 0。用户随后表示自行安装，USB 操作已暂停，等待完成确认；不能将已解包或签名有效写作“驱动已安装”。此期间仅继续与 USB 无关的本地 FPGA 模块开发和仿真。

该资料包的 `Firmware/FX2LP firmware/slave.c` 使用 48 MHz 内部 IFCLK、16 位 Slave FIFO、EP2 OUT 和 EP6 IN；这是可审查的候选源代码，不是当前硬件固件的回读证据。尚未执行 firmware RAM/EEPROM 写入。

## 驱动安装后的只读检查

2026-09-12 用户确认 Cypress 驱动已安装并自行烧写 FX2 固件，提供的文件为 `C:\Users\JITIANRUI\Downloads\05_驱动和常用软件\小软件\FX2_USB_工具\FX2_USB_工具\Firmware\FX2LP firmware\slave.iic`。文件长度 2718 字节，SHA-256 为 `E3C2C8C3CB9F1D4B52F205ACEC3DF010CCD88BB4D47E57AF9055CD4F836870F4`。本次恢复只读 USB 检查；助手未执行烧写、复位或 FIFO 数据传输。

Windows PnP：Cypress 04B4:00F1 为 Status=OK、ProblemCode=0，绑定 oem2.inf、CYUSB3 服务、驱动 1.2.3.10；FTDI 下载器也为 OK。INF 的“Cypress FX3 USB StreamerExample Device”名称来自共享 VID/PID 匹配，不改变实物为 FX2 的事实，无需为名称替换驱动。

独立脚本 `scripts/inspect_usb.ps1` 使用资料包 CyUSB.dll 1.2.2.0，仅查询属性和标准 GET_DESCRIPTOR。先前限定 PID=00F1 的筛选失败，不是驱动无法打开：实际库 Count=1、句柄有效。库与标准 GET_DESCRIPTOR 的实时结果均为 **04B4:1004**，Product 属性为 EZ-USB；标准设备描述符原始字节为 `12-01-00-02-00-00-00-40-B4-04-04-10-00-00-01-02-00-01`。这与 Windows 缓存的 00F1 及所提供 slave.iic 内的 00F1 描述符不同，不能仅归咎于库属性或显示名称。

库同时返回 HighSpeed=true、SuperSpeed=false、配置 1/接口 1/alternate 0；批量端点为 0x02 OUT、0x86 IN，最大包长均为 512 字节，EP0 为 64 字节。这证明主机接口可打开并响应描述符请求；不证明运行中的 FIFO 寄存器与 slave.c 一致，也不证明实际采集吞吐。

同目录 slave.c 明确配置 IFCONFIG=E3、PINFLAGSAB=81、PINFLAGSCD=1E、EP2CFG=A0、EP6CFG=E0、EP2FIFOCFG=11、EP6FIFOCFG=0D。dscr.a51 高速端点为 02/86；其全速描述符却写为 04/88，而初始化禁用 EP4/EP8，因此当前候选固件不应声称支持全速降级。现在主机读数为高速模式，后续连接必须检查速度/端点，异常则拒绝开始采集。

当前最可能的解释是 EEPROM 烧写后 RAM 中仍运行临时编程固件，尚待硬件复位加载 slave.iic；这是推断，尚非硬件回读结论。Infineon 明确说明 Control Center 烧写 EEPROM 时会先在 RAM 加载 Vend_Ax，且这一步可能不重新枚举；EEPROM 更新后需复位才能加载新内容。下一步先确认用户烧写后是否执行 FX2 硬件复位，不发送不明 vendor 命令、不把仅拔插 J5 当作必然断电（板载下载器仍可供电）。

依据：[Infineon，Control Center 的 EEPROM 编程过程](https://community.infineon.com/t5/USB-low-full-high-speed/flash-EEPROM-with-I2C/td-p/131262)；[Infineon，Vend_Ax 与复位后的描述符变化](https://community.infineon.com/t5/Knowledge-Base-Articles/No-FX2-vend-ax-example-tutorial/ta-p/258475)；[Microsoft，标准 GET_DESCRIPTOR 控制传输](https://learn.microsoft.com/en-us/windows-hardware/drivers/usbcon/usb-control-transfer)。接口实测与本地源码证据区分保存，不将源码写作固件回读。

随后用户确认完成整板断电重启。重启后的标准 GET_DESCRIPTOR 返回 `12-01-00-02-00-00-00-40-B4-04-F1-00-00-00-01-02-00-01`，实时 VID/PID 为 **04B4:00F1**；库属性同样为 00F1，Product 恢复为 `EZ-USB FX2 GPIF to Ext FIFO Example using Single Transactions`。HighSpeed=true、配置 1、接口 1、alternate 0、EP2 OUT/EP6 IN 各 512 字节仍正常。此前实时 PID 差异已经消除，无需继续等待复位或修改驱动。该结果与目标固件启动一致，但尚未逐字节回读 EEPROM/运行程序或测量 IFCLK/FIFO 传输，不能据此宣称全系统链路已完成。

## USB 接口区分

首次有限帧采集更新：AFE 启动状态机实板完成；ILA 已捕获四帧 2048 点，数字下标/帧号/422.8 µs 时间戳周期正确，但 ADC 原始和对齐值全部为 0。当前不能认为得到有效光谱，需核查子板供电及模拟/数字链路。已停止并恢复 hold_reset=1/run=0，详见 diagnostic_bringup.md 最新节。

最新 FPGA 状态：2026-09-12 已授权下载独立诊断位流，实际 ILA=1/VIO=1，locked=1、hold_reset=1、run=0。之前“未下载新设计/无调试核”的记录为历史状态，已被此次易失配置替换；未写 Flash，未启动 CCD 采集。配置 Bank0 属性已由原理图核对补齐。详情及位流 SHA-256 见 diagnostic_bringup.md。

用户提供的 ACX720-V3 原理图 PDF 第 5 页中，高速 USB 接口为 **J5**，其 D+/D− 接到 U20 CY7C68013A；第 9 页的 **J2** 接 CH340E，是 USB UART。这是所提供原理图的连接关系，不能未经板载下载器版本核对就认定为实物 Type-C 的连接关系。JTAG 下载调试已连通，也不证明 SPIF 连续数据收发通道已经建立。

保持当前已正常工作的板载下载器连接，按用户最新确认另接 J5 数据口。连接后先只读检查名称、VID/PID 和驱动状态。此阶段不安装或替换驱动、不写 FX2 EEPROM，也不按未知功能的按键。提供的 Xilinx_Debugger.pdf 留作下载器资料，不再以 HS2 的数据通道研究作为项目推进前提。

## 分阶段验证

1. 已完成：下载器与实际器件识别、配置状态读取、现有调试核清点。
2. 初始 5 MHz 前端波形、ADC 对齐及缓存联合仿真已完成，前端 OOC 综合为 290 LUT/461 FF；带实际 ILA/VIO 的诊断顶层现已完成布局布线（2441 LUT、3919 FF、36 RAMB36，已约束路径 WNS +3.606 ns / WHS +0.055 ns），详见 diagnostic_bringup.md。配置电压属性与外部 IO 时序尚未补齐，未生成或下载位流。下载前明确对应位流、输出时钟和复位状态，不把内部路径余量当作 ADC 采样窗口证明。实际采样窗口及更高速配置仍须测量验证。
3. 数字与模拟对照：在传感器/AFE 的实际引脚处测量 φ1/φ2、SH、RS、CP、SHP、SHD、DATACLK；同时用 ILA 对照像素序号、12 位数据和帧边界。需要用户协助连接示波器探头并提供波形；具体测点和设置随诊断顶层确定。ILA 不能验证 5 V 模拟阈值或驱动器延迟。
4. 数据链路：采用 J5/FX2，核对接口枚举、固件和驱动、FIFO 时钟/端点/标志配置。JTAG 调试核用于有限帧诊断，不代替连续全光谱数据链路。先用已知计数测试数据完整性，再接入真实 CCD 和距离包。
5. 标定及长测：通过上位机采集 S、导入真实 K，等待硬件 ACK 并绑定版本，验证全帧连续性、文件回放和实际距离误差。

## 只读检查脚本

`scripts/inspect_hardware.tcl` 使用 Vivado 2018.3 的 `open_hw`/`close_hw`，而不是较新版的 manager 命令。连接 localhost:3121 硬件服务，读取目标与配置/启动状态，枚举 ILA/VIO 后关闭本次连接。脚本不含 PROGRAM.FILE、program_hw_devices 或 Flash 操作，且只打印配置/启动状态，不枚举密钥或器件唯一标识寄存器。

命令依据：[AMD/Xilinx UG835 v2018.3（2018-12-05），open_hw/close_hw](https://docs.amd.com/api/khub/documents/wNJReNjblikQ29AHV1THwg/content)。硬件接口依据：本地 ACX720-V3-SCH.pdf，第 5、9 页；读数证据：build/hardware_discovery.log。

USB 错误码依据：[Microsoft Learn，Code 28 / CM_PROB_FAILED_INSTALL](https://learn.microsoft.com/en-us/windows-hardware/drivers/install/cm-prob-failed-install)。FX2 枚举、属性及本地签名验证通过 PowerShell 只读查询获取，未借此修改下载器或系统安全设置。
