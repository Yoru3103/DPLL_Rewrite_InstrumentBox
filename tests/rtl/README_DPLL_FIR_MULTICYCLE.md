# DPLL FIR 输入多周期路径的功能证明

从项目根目录执行：

```powershell
powershell -ExecutionPolicy Bypass -File tests/rtl/run_dpll_fir_multicycle.ps1
```

Vivado 不在默认位置时使用 `-VivadoBin "实际安装路径\bin"`。结果保存在被 Git 忽略的 `autotune_complete.sim/dpll_fir_multicycle/`，通过标志为 `PASS: production boxcar and FIR wrapper`。脚本检查进程退出码、断言失败以及通过标志。

测试直接编译生产 `DigitalPLL/DDC/boxcar_2_pts_filter.vhd` 与 `DigitalPLL/DDC/N_times_clk_FIR_wrapper.vhd`，不复制或改写待测 RTL。测试文件提供同名 `fir_compiler_minimumphase` 行为替身，作为 wrapper 输出有效拍的检查器；它不验证 FIR 滤波算法或 IP 内部时序，因此必须使用脚本创建的独立 work 库。

七个并行实例分别采用 0、0.1、0.5、1、2、3、3.9 ns 的慢时钟相位偏移，快时钟周期为 4 ns，慢时钟周期为 320 ns。每个实例输入64个变化样本，断言：

- 初始信号为0时不会产生虚假传输。
- FIR 首次接收时刻为182 ns，后续接收间隔严格为320 ns。
- boxcar 输出的数据值和顺序正确，没有重复、漏样或撕裂。
- 时钟停止后最后一个样本仍已送达，接收总数恰为64。

零偏移时的证据链是：162 ns 的共同边沿产生新 `sum_register` 和新 toggle；166 ns 更新 d1；170 ns 更新 d2，但 d2/d3 比较仍读取旧值；174 ns 才使能 `data_times_N` 并捕获新数据；178 ns 经过额外输入寄存器；182 ns 被 FIR 接受。这为该首级数据寄存器 D 端采用 `setup 3 -end`、配套 `hold 2 -end` 提供功能依据。

约束必须仅覆盖 DPLL I/Q 两路首级 `data_times_N_reg[0..15]/D`，合计32个端点；不得包含后一级 `data_times_N_reg_reg`、CE 或整个时钟组。toggle 的 d1/d2 使用 `ASYNC_REG`，跨域例外仅限 I/Q 两个第一级 d1 的 D 端的 setup，保留这两个首级的普通 hold 检查以保证共同边沿不提前采到新 toggle；d1→d2、d2→d3 及使能控制路径仍需以普通 setup/hold 约束通过实际实现。boxcar 数据和 toggle 均在同一慢时钟边沿无条件更新，且两者没有独立的运行时复位；上层 `rst` 不改变这一配对关系。

这些测试不模拟亚稳态、器件传播延迟或板上时钟抖动，也不能替代静态时序分析。测频模块使用独立 `N_times_clk_FIR_wrapper_H`，其125 MHz→250 MHz倍率不属于此约束和测试的适用范围。

与旧两级边沿检测相比，新同步链将输入采样及 FIR 接收延后一个250 MHz周期，即4 ns。源数据保持320 ns，因此此延迟不触及下一源数据更新；它不能直接用于125 MHz→250 MHz的测频 wrapper。下游慢时钟输出是否额外延迟一个320 ns周期，取决于真实 FIR IP 输出有效拍相对慢时钟边沿的位置；本测试使用FIR替身，不能据此宣称慢域输出延迟保持不变，须另行核对真实IP延迟/仿真。

## 真实 FIR IP 的慢域延迟对照

```powershell
powershell -ExecutionPolicy Bypass -File tests/rtl/run_dpll_fir_ip_latency.ps1
```

全新检出仓库后，先在Vivado为 `fir_compiler_minimumphase` 执行 Generate Output Products；功能网表属于生成文件，不提交Git，脚本在缺失时会明确报错。该测试加载项目已有的 `fir_compiler_minimumphase_sim_netlist.vhdl` 功能网表及 UNISIM 模型，把新生产 wrapper 与旧边沿检测参考逻辑置于相同输入。七种相位各输入512个伪随机样本，跳过200个启动样本后逐个比较312个慢域输出；要求均非未知值且至少100次输出变化，防止全零误通过。该测试未使用 FIR 替身，结果输出到 `autotune_complete.sim/dpll_fir_ip_latency_vhdl/`，通过标志为 `PASS: real FIR IP old/new wrappers`。2026-09-20 使用 Vivado 2018.3 实际运行通过：七个相位合计2184个暖机后的慢域样本逐点一致。

生成IP参数为 `C_LATENCY=88`、`C_OVERSAMPLING_RATE=80`。输入的4 ns变化相对于352 ns的IP流水及约8 ns输出寄存器延迟，令源到输出就绪约从376 ns变成380 ns；两者仍在640 ns的慢域捕获边沿前，名义余量约260 ns。功能仿真用于确认本配置下慢域输出序列与采样延迟不变；若将来修改IP延迟、时钟比或输出寄存器，必须重新核对，不能只沿用此结论。
