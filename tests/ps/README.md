# 阶段 5A：PS 指标与接口自检

在项目根目录用 PowerShell 执行（不连接板卡）：

```powershell
New-Item -ItemType Directory -Force autotune_stage5a.sim | Out-Null
gcc -std=c99 -Wall -Wextra -Werror -I tests/ps/include -I DPLL_Rewrite.sdk/DPLL_2COM_v2/src tests/ps/test_adaptive_metrics.c DPLL_Rewrite.sdk/DPLL_2COM_v2/src/AdaptivePlIf.c DPLL_Rewrite.sdk/DPLL_2COM_v2/src/AdaptiveMetrics.c -lm -o autotune_stage5a.sim/test_adaptive_metrics.exe
if ($LASTEXITCODE -ne 0) { throw 'C build failed' }
./autotune_stage5a.sim/test_adaptive_metrics.exe
if ($LASTEXITCODE -ne 0) { throw 'C test failed' }
```

通过标志：`PASS: adaptive metrics HAL and calculation self-check`。

生产顶层的寄存器映射、CDC 字段顺序与 1024 bit 总位宽检查：`python tests/ps/test_metric_wiring.py`，要求 2 项测试通过。该静态接口检查不能替代完整顶层 elaboration 和物理 CDC 验证。

覆盖有符号寄存器拼接、平方和高位、完整快照重试/耗尽、旧/未知扩展能力、零样本、异常计数/方差、偏差与 RMS/标准差区别、相位端点斜率、锁定不完整和相位饱和时趋势不可用。

`include/` 是本机测试桩，不用于 SDK。固件使用 BSP 的 xil_types/xil_io。

ARM 编译使用 Cortex-A9/VFPv3 hard-float，与现有 SDK 一致。SDK 刷新 source 后应包含 `AdaptiveMetrics.c`；该模块使用 sqrt，项目 `.cproject` 的 Debug/Release 链接库已加入 `m`（GCC `-lm`），不修改自动生成的 Debug makefile。目前现行评分没有调用这个诊断计算器，不能据编译成功声称新指标已参与选参。

窗口管理、翻转率和新选参状态机属于后续阶段；这些测试不替代 UART/状态机/上板验证。
