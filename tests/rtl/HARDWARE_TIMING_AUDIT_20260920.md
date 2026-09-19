# Autotune 整机硬件时序审查（2026-09-20）

本记录先保留原 `impl_1` 检查点的失败证据，再记录本次修复和最终实现结果。原始依据为 `autotune_complete.sim/full_timing.rpt`（Vivado 2018.3，报告时间 2026-09-20 00:56:10）和 `full_cdc.rpt`。

## 实测报告结论

- Setup WNS **-4.693 ns**，TNS **-9329.771 ns**，5299 个 setup 失败终点；Hold WHS **+0.048 ns**。
- `check_timing` 报告无未定义时钟、无未约束内部最大延迟终点，但有 42 个输出端口未给 output delay。这些数字不能证明板级 IO 时序已完整验证。
- `report_cdc` 仅报告 `All paths are Safely Timed`。工具将相关时钟间路径纳入同步时序分析；该句不能推翻上述 setup 违例，亦不能替代 bundled-data 协议和板级时钟关系审查。

## 主要证据及实际影响

| 路径 | Slack | 解释及影响 |
|---|---:|---|
| `i_ps/axi_slave_gp0/rd_do_reg` → `dpll_wrapper_inst/sys_rdata_reg[22]` | -4.693 ns | 最坏路径为普通总线读取路径，数据延迟 6.894 ns，但时钟 skew 为 -5.662 ns；错误可能破坏寄存器数据/总线行为，PS 一致性重读不能替代硬件时序闭合。 |
| `Digital_Freq_Meter_inst/adaptive_parameter_commit/loop_gain_changed_reg` → PID D 支路乘法器同步清零端 | -2.109 ns | 原子提交后的参数变化通知为高扇出路径，9.520 ns 数据延迟中 8.878 ns 为布线；可能使滤波器各寄存器不同拍清零，直接影响参数切换。 |
| DPLL 正限幅寄存器 → `output_summing_dac0/data_output_reg` | -2.720 ns | 125 MHz 配置域到 3.125 MHz 回路域的相关时钟路径仍只有 8 ns STA 要求；限幅配置及输出逻辑也有违例。 |
| DPLL DDC 输出 → `sys_rdata_reg` | -2.967 ns | 慢回路到总线域的旧直接读出路径未闭合。 |
| DPLL `angleSelect` 配置 → `adaptive_loop_statistics/frequency_square` DSP 输入 | -1.630 ns | 统计模块与旧配置选择链相关的跨域路径也有失败，不能称 Autotune 所有硬件路径均通过。 |

DPLL 统计模块同一 3.125 MHz 域的最坏报告路径余量为 **+305.764 ns**，所以主要问题不是在 3.125 MHz 下计算平方和过慢。整机同时存在 125 MHz、250 MHz 和 PS 外设域的其他违例。单模块 OOC 综合不能覆盖这些问题。

## 有限修复建议（未经重新实现验证）

1. **优先统一总线时钟。** `red_pitaya_top.v` 当前 `i_ps.axi0_clk_i` 连接 `adc_clk_in`（IBUFDS 原始输出），两个回路的总线却使用 `adc_clk`（PLL 输出经 BUFG）。报告中前者直接分发到 261 个负载，原始时钟布线延迟 2.430 ns。将 `axi0_clk_i` 改接现有 `adc_clk`，使 PS GP0 ACLK、AXI 桥和总线从设备使用同一全局时钟。修改后必须重新检查启动复位和全部 setup/hold，不能据一行修改就宣布通过。
2. 对测频 `gain_changed` 清零网采用物理高扇出优化/寄存器复制；如需要增加流水，必须让各 PID 支路清零与参数生效保持一致并补充仿真。不可直接将真实路径设为 false path。
3. 将 DPLL 的慢变配置在回路域通过完整提交协议锁存，或增加明确的本地寄存器级，缩短“配置选择器→运算”路径。参数要按整组一致性处理；不能只逐位同步多位总线。旧 DDC 直接读出若改为快照，也须匹配软件读数语义。
4. 重新实现并检查时序、时钟关系、统计采样数和接口版本，再导出与新 bit 匹配的硬件平台。不要使用引用旧平台的既有 bootimage 配置生成发布包。

旧实现包含平方和/饱和统计，仅能证明它具备部分新指标逻辑；还需核对其测频窗口是否为当前 PS 所要求的 **131072**，锁相窗口是否为 **4096**。窗口版本不匹配应由 PS 拒绝，不能用于整定。

以上为修改前的初始审查证据；不能将这个既有时序失败的 bitstream 标记为可上板验收版本。后续修复与最终实现结果见下节。

原始时序报告 SHA-256：`75cc080c515cd43256cc6ae33ec2f418305204ee2fd6052575b21c07ebe15b72`。

## 本轮已实施的有限硬件修复

1. GP0 AXI 桥与两个总线从设备统一使用已有的 `adc_clk` 全局缓冲时钟。复位来自独立 PS FCLK reset，不引入时钟与复位的循环依赖。
2. `angleSelect` 在 DPLL 3.125 MHz 域本地寄存后再选择 DDC 输出；原总线配置及回读地址保留。
3. 旧实时读回 0x0101—0x0107 增加一个125 MHz预采样寄存器级（8 ns），地址译码和 `sys_ack` 拍序保持不变。Autotune使用的完整窗口快照CDC独立，不受此旧读数预采样影响。`test_dpll_readback.py` 提取生产RTL回归7个地址、每拍ACK、延迟和复位，已通过。
4. DPLL FIR 的 toggle 改用两级 `ASYNC_REG` 同步和第三级历史值检测。输入捕获/FIR接收较旧实现延后4 ns；独立125→250 MHz的测频 `_H` wrapper不变。生产VHDL七相位×64样本回归通过，详见 [FIR证明](README_DPLL_FIR_MULTICYCLE.md)。
5. FIR数据MCP严格限定到32个首级D端（I/Q各16位），源为32个boxcar sum寄存器，`setup 3 -end` / `hold 2 -end`。只对两个同步首级D应用 `set_false_path -setup`，保留其普通hold。共同名义时钟沿必须采到旧toggle，才能据第三个后续快沿推导MCP3；这由最终首级hold非空且非负断言检查。
6. PWM八位比较拆成同一流水拍的高位小于/相等及低位小于等于，再合并输出；131072个比较输入组合、六种FULL、动态配置、复位和器件INIT模型逐周期等价通过。原始 `impl_1` 四通道的 `v_r_reg` 与 `vcnt_r_reg` 共64个实际FF均为 `INIT=1'b0`，证据为 `autotune_complete.sim/read_pwm_original_init.log`。新比较谓词初值0/1/1保持对应的0≤0行为。

仅统一总线时钟后的第一轮完整布线为 WNS -1.299 ns、TNS -44.497 ns、WHS +0.052 ns，仍不能发布。依据保留在 `autotune_complete.sim/rebuild_timing.log` 的 Post Routing Timing Summary；没有把这轮位流作为通过版本。

## 可复现构建与验收边界

项目根目录执行：

```powershell
./tests/rtl/build_autotune_hardware.ps1
```

构建使用专用 `autotune_synth_20260920` / `autotune_impl_20260920` run，保留旧 `impl_1`；工程默认run切换到专用run。最终完整报告、精化后的DCP、bit/HWDEF/HDF位于 `autotune_complete.sim/hardware/`。最终文件以此目录为准，GUI中专用run的route-only状态和中途报告不能替代精化后的结果。

Vivado 2018.3的XDC不支持顶层`if`。因此精确选择器数量及四个`ASYNC_REG`属性断言放在 `check_dpll_fir_objects.tcl`，由 `check_autotune_hardware_objects.tcl` 连同真实VCO DSP流水断言执行（link后pre-hook及最终导出前各检查一次），XDC只保留支持的时序命令。最终脚本 `finalize_autotune_hardware.tcl` 会使用从干净综合/实现加载的仅setup例外、独立检查两个firstD hold路径以及d1→d2的max/min路径非空、slack为有限数值且通过，并要求全局setup、hold、pulse-width均非负、失败终点数为0。统计窗口实际触发计数器位宽必须分别为17和12。任何一项失败都应停止发布，不能使用目录中的旧产物。

板级42个未指定output delay端口仍需结合原理图、外设时钟和板上测试验收；内部STA闭合不能证明这些IO路径已完成外部时序验证。

## 第二轮物理实现证据

第二轮完成route及Explore后优化：WNS **-0.072 ns**、TNS **-3.461 ns**，48个setup失败端点；WHS **+0.034 ns**、WPWS **0.000 ns**。失败集中于原VCO 48×16乘法器的一级流水DSP级联路径。布局阶段已把5个寄存器移入DSP，后续两轮DSP优化无候选；Vivado 2018.3不支持post-route的`-dsp_register_opt`，实际试验确认不支持，而非认为该选项优化后通过。此轮未生成发布bit。

该版本Vivado在`report_cdc -details`出现EXCEPTION_ACCESS_VIOLATION，独立时序报告和DCP已保存；崩溃诊断仅留在忽略目录，不纳入源码交付。首级例外精化试验还确认：旧checkpoint中的完整false path不能仅靠追加setup-only约束去除hold豁免，工具可能返回`Slack: inf`。因此最终验证拒绝Inf/NaN，不以“路径非空、且不小于零”作为充分通过条件，并从干净实现加载setup-only约束。

真实生产FIR IP回归也已通过：七相位、每相位512激励，暖机后共2184个slow输出逐点一致、非X且实际变化。新增4 ns输入延迟没有改变当前IP下的slow输出采样周期，详见FIR证明文档及`run_dpll_fir_ip_latency.ps1`。

## VCO流水及旧IP缓存修复

VCO乘法器配置从PipeStages=1改为2，实际DSP网表为三颗DSP均启用AREG、首颗启用BREG、末颗启用PREG。它增加DSP输入寄存级；并未在两个DSP的PC级联之间插入MREG。乘法结果和valid延迟8 ns，除数同步延迟8 ns以保留动态配置时原有事务关联；乘数采样时刻保持不变。

真实乘法/除法IP对照回归通过：两个slow相位（含快慢上升沿重合），每个1000笔输入/输出、末尾400拍排空无丢失，约40300拍完整输出流严格只延迟8 ns，并覆盖每拍变化的乘/除因子。详见 [VCO流水回归](VCO_PIPELINE.md)。

实际检查发现`generate_target all`只更新了模型，原位置的2020年一级DCP仍会被主工程静默链接。因此构建现在必须先执行 `rebuild_autotune_vco_ip.tcl` 中的 `synth_ip -force`，并在实现链接后与最终导出前校验三颗DSP的AREG、首颗BREG及末颗PREG。第三轮在旧DCP被链接的早期即停止，保留正确的新顶层综合；强制生成新IP后才重新链接进入正式布局布线。不能仅凭XCI的PipeStages=2宣称实际硬件已更新。


## 最终第三轮实现与导出（已通过）

2026-09-20 02:18:25 完成最终布线后优化、断言检查与位流/HDF导出，日志包含 `AUTOTUNE_BITSTREAM_GENERATED=1`。最终 `hardware/timing_summary.rpt`：

| 检查 | 结果 |
|---|---|
| Setup WNS / TNS | **+0.065 ns / 0.000 ns**，0个失败终点 |
| Hold WHS / THS | **+0.054 ns / 0.000 ns**，0个失败终点 |
| Pulse-width WPWS / TPWS | **0.000 ns / 0.000 ns**，0个失败终点 |
| 无时钟寄存器 / 未约束内部最大延迟 | **0 / 0** |
| FIR两个首级D的普通hold | **+0.830 / +0.899 ns**，均为有限值 |
| FIR d1→d2普通setup | **+2.711 / +3.244 ns** |
| FIR d1→d2普通hold | **+0.122 / +0.292 ns** |
| 实际统计窗口计数器 | 测频17位、DPLL 12位，对应131072/4096样本 |
| 写bit前DRC | **0 Errors**；保留40项Warning及28项Advisory |

最终DCP导出的 `effective_constraints.xdc` 与 `exceptions.rpt` 确认，FIR首级仅豁免setup，数据仅为精确32位的MCP3/hold2；原完整false path没有残留到FIR首级hold。报告中的另一项完整false path来自既有PS复位IP `i_ps/system_i/system_i/rst_ps7_0_200M/U0/*cdc_to*/D`，与FIR无关。FIR约束在实现加载和最终核对时同样读取，因此报告中存在两份相同约束；它们的数值和作用对象一致，未扩大例外。

02:19:58，单线程独立Vivado进程对这个最终DCP完成 `report_cdc -summary` 和 `-details`，退出0并输出 `AUTOTUNE_CDC_REPORT_COMPLETED=1`。最终报告中Unsafe、Unknown、No ASYNC_REG均为0，相关时钟路径为Safely Timed。该结论结合已通过的完整STA、同步器结构断言及FIR相位/真实IP回归使用；不能单独作为异步协议或板级IO验收证明。旧失败轮CDC报告已归档，正式 `cdc.rpt` 只在本次报告成功后生成。

当前GUI默认综合/实现均已切到专用Autotune run。Vivado route-only在启用post-route优化时的真实状态为 `Not started phys_opt_design (Post-Route)`，83.333%进度；最终优化在导出的DCP上完成，权威产物为下表，不能以GUI中间状态代替。构建脚本同时核对run状态、本轮route完成标记及检查点时间戳，主PowerShell入口检查导出完成标志。本次强制重建IP在顶层综合之后发生，顶层仍为相同IP黑盒，最终DSP连接已严格断言；GUI可显示NEEDS_REFRESH。可复现入口已将IP强制重建放到干净顶层综合之前，不篡改refresh状态。

| 最终工件（`autotune_complete.sim/hardware/`） | SHA-256 |
|---|---|
| `red_pitaya_top_autotune.bit`（2,083,850字节） | `9445a68feec97644ed96d8953cb7ff27c439b4fba15100349bed965b4d7ec582` |
| `red_pitaya_top_autotune.hdf` | `c0c63a84a8052253d0c3f56a7ca1eec908a3ac747c9b6507d868833414ff8854` |
| `autotune_postroute.dcp` | `33ae126b0caa3461bb2d1cedfa409013ae65371cf8e7fbfa9269b65ea2cd26c6` |
| `timing_summary.rpt` | `ecc5de72a9a09de911d17a0430fc36164114011bab17e73e1a4ca4f9e6ed9001` |
| `cdc.rpt` | `70a6162cfc9741bbe3c94ef9f991d6971d3dcdbdb870a279b147670fca71af95` |

已检查HDF内嵌bit的SHA-256与独立bit完全一致。`write_autotune_hardware_manifest.ps1`刷新 `source_sha256.txt` 和 `artifact_sha256.txt`，记录关键RTL、约束、真实VCO IP DCP、构建检查脚本及最终报告来源。位流与硬件导出已冻结，可供单独BOOT包使用。

本次完成的是内部实现时序、软件/RTL回归及匹配启动包准备，未执行烧写。42个未设置output delay的端口以及真实输入范围、接线、噪声、参数变化后的闭环动态效果仍需上板验收；已有的PLL输出缓冲类型等DRC Warning也保留供板级验收审查。最小setup余量较小，任何后续RTL/IP/约束变化都必须重新进行完整实现验证。
