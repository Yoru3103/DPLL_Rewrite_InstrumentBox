# 阶段 3 RTL 自检

在项目根目录、Vivado 2018.3 命令可用时执行：

```powershell
xvlog DPLL_Rewrite.srcs/sources_1/Adaptive/adaptive_statistics.v `
      DPLL_Rewrite.srcs/sources_1/Adaptive/adaptive_snapshot_cdc.v `
      DPLL_Rewrite.srcs/sources_1/Adaptive/adaptive_param_commit_same_clock.v `
      DPLL_Rewrite.srcs/sources_1/Adaptive/adaptive_param_commit_cdc.v `
      tests/rtl/tb_adaptive_stage3.v
xelab tb_adaptive_stage3 -s tb_adaptive_stage3_sim
xsim tb_adaptive_stage3_sim -runall
```

通过标志为：

```text
PASS: adaptive stage 3 RTL self-check
```

该自检覆盖 4 点小窗口统计、同域原子提交、重复/忙提交拒绝、legacy 回退、125 MHz 与异步相位 3.125 MHz 等效时钟之间的 request/ack，以及 bundled-data 快照传输。

可选的统计模块独立综合检查：

```powershell
vivado -mode batch -source tests/rtl/synth_adaptive_statistics.tcl
```

独立综合只用于提前发现可综合性和明显资源问题，不能替代完整工程的综合、实现、CDC 报告和板上验收。

## 阶段 5A 扩展自检

新增 `tb_adaptive_metrics.v`，覆盖 64 个可重复随机窗口、二补码极值、精确平方和、首末样本、OR 计数、相位饱和、跨窗口清零、冻结快照、1024 位 CDC、最小 2 点窗口，以及实际测频 131072 点窗口。旧阶段 3 自检继续运行以检查兼容性。

推荐在生成目录运行（项目根目录启动，先将 Vivado 2018.3 bin 加入 PATH）：

```powershell
New-Item -ItemType Directory -Force autotune_stage5a.sim | Out-Null
Push-Location autotune_stage5a.sim
try {
    xvlog ../DPLL_Rewrite.srcs/sources_1/Adaptive/adaptive_statistics.v ../DPLL_Rewrite.srcs/sources_1/Adaptive/adaptive_snapshot_cdc.v ../DPLL_Rewrite.srcs/sources_1/Adaptive/adaptive_param_commit_same_clock.v ../DPLL_Rewrite.srcs/sources_1/Adaptive/adaptive_param_commit_cdc.v ../tests/rtl/tb_adaptive_stage3.v ../tests/rtl/tb_adaptive_metrics.v ../DPLL_Rewrite.srcs/sources_1/Freq_Meter/Digital_Freq_Meter.v ../DPLL_Rewrite.srcs/sources_1/DigitalPLL/dpll_wrapper.v
    if ($LASTEXITCODE -ne 0) { throw 'RTL parsing failed' }
    foreach ($test in @('tb_adaptive_metrics', 'tb_adaptive_stage3')) {
        xelab $test -s "${test}_sim"
        if ($LASTEXITCODE -ne 0) { throw 'RTL elaboration failed' }
        xsim "${test}_sim" -runall -log "${test}.log"
        if ($LASTEXITCODE -ne 0 -or -not (Select-String -Path "${test}.log" -Pattern 'PASS:')) { throw 'RTL self-check failed' }
    }
    vivado -mode batch -source ../tests/rtl/synth_adaptive_metrics.tcl
    if ($LASTEXITCODE -ne 0) { throw 'Standalone synthesis failed' }
} finally { Pop-Location }
```

扩展通过标志为 `PASS: adaptive metrics RTL self-check`。未连接的测试输出告警是有意保留；生产顶层扩展字段均连接。

独立综合分别检查 WINDOW_LOG2=17/12，统一使用 8 ns 时钟约束。生成 metrics_17/12 的资源和时序报告；不能据此宣称完整工程时序或物理 CDC 约束已经通过。
