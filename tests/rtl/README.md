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
