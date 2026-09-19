# PS Autotune 与指标自检

在项目根目录用 PowerShell 执行，不连接板卡。本机测试直接编译生产 `AutotuneEngine.c`、`AdaptiveMetrics.c`；`include/` 只提供本机 Xilinx 类型/寄存器桩，SDK 使用 BSP 头文件。

```powershell
New-Item -ItemType Directory -Force autotune_stage5a.sim | Out-Null
$env:PATH='C:\msys64\ucrt64\bin;'+$env:PATH

gcc -std=c99 -Wall -Wextra -Werror -I tests/ps/include -I DPLL_Rewrite.sdk/DPLL_2COM_v2/src tests/ps/test_autotune_engine.c DPLL_Rewrite.sdk/DPLL_2COM_v2/src/AutotuneEngine.c DPLL_Rewrite.sdk/DPLL_2COM_v2/src/AdaptiveMetrics.c -lm -o autotune_stage5a.sim/test_autotune_engine.exe
if ($LASTEXITCODE -ne 0) { throw 'engine build failed' }
./autotune_stage5a.sim/test_autotune_engine.exe
if ($LASTEXITCODE -ne 0) { throw 'engine test failed' }

gcc -std=c99 -Wall -Wextra -Werror -I tests/ps/include -I DPLL_Rewrite.sdk/DPLL_2COM_v2/src tests/ps/test_adaptive_metrics.c DPLL_Rewrite.sdk/DPLL_2COM_v2/src/AdaptivePlIf.c DPLL_Rewrite.sdk/DPLL_2COM_v2/src/AdaptiveMetrics.c -lm -o autotune_stage5a.sim/test_adaptive_metrics.exe
if ($LASTEXITCODE -ne 0) { throw 'metrics build failed' }
./autotune_stage5a.sim/test_adaptive_metrics.exe
if ($LASTEXITCODE -ne 0) { throw 'metrics test failed' }
python tests/ps/test_metric_wiring.py
```

## 生产状态机覆盖

- 校准后冻结尺度与死区，再独立采集基线；完整33轮正常流程、明确改善、无改善、重复轮波动否决，以及相同原参数候选不得误报调参成功。
- ORIGINAL控制复测漂移、最佳候选复验变差、限幅/失锁候选淘汰与恢复。
- 候选期间/复验期间取消，原参数完整恢复，提交失败，恢复提交失败，恢复锁定失败。
- 旧指标接口、运行中接口消失、错误计数、历史事件倒退、读失败、覆盖不足、序号异常增长、总超时。
- 真实125MHz/131072及3.125MHz/4096时钟窗口节奏下的重复快照与覆盖率。
- 32位时间回卷、快照序号回卷并跳过0、8位runId回卷并跳过0。
- 死区边界、相邻符号翻转、重复/缺失快照断开邻接、相位趋势失效与饱和。
- 有符号均值/RMS/标准差/MAE/端点斜率/输出余量、准确OR计数边界、事件差。
- 真实RTL的频率负极值：legacy绝对值8191，但signed/square对应-8192；不能误拒绝。
- 9页冻结报告、冻结runId、组均分与末轮分数分离、末轮指标可复算、clear和配置边界。

三行 `PASS` 表示状态机、窗口累加、冻结报告/生命周期测试均通过。

## 指标HAL与RTL接口

`test_adaptive_metrics.c` 覆盖寄存器64位拼接、平方和高位、完整快照重试、旧能力、异常数据及相位趋势有效性。`test_metric_wiring.py` 检查两路寄存器映射、CDC字段顺序与1024位快照；这些检查不能替代完整顶层实现和物理CDC验证。

ARM编译使用 Cortex-A9/VFPv3 hard-float，与现有SDK一致；`AutotuneEngine.c`、`AdaptiveMetrics.c` 均应参与SDK构建并链接数学库 `m`。离线测试不模拟真实被控对象，不等同于PID性能标定或上板验收。

## 一次完成自检和固件链接

本机已安装GCC、Python和Xilinx SDK 2018.3，使用现有BSP时，在项目根目录执行：

```powershell
$env:PATH='C:\msys64\ucrt64\bin;D:\Xilinx\SDK\2018.3\gnu\aarch32\nt\gcc-arm-none-eabi\bin;'+$env:PATH
./tests/ps/build_autotune.ps1
```

脚本执行上述生产C自检、Python适配器/静态映射测试，再编译并链接完整ARM应用（包含libxil/libm）。输出位于忽略目录 `autotune_complete.sim/DPLL_2COM_v2_autotune.elf`，同时输出SHA256。可用 `-SkipTests` 仅重新构建固件。脚本不烧写设备，不使用旧Debug makefile。

上位机回归必须从 `host_app` 目录运行 `python -m unittest discover -s tests -v`。RTL回归另见 [RTL自检](../rtl/README.md)。应用ELF不包含bitstream或FSBL，启动镜像必须使用同次验证过的匹配硬件；旧bootimage配置引用的2024年bitstream不适用。

FSBL也可从现有源码重建：在同一工具PATH下执行 `./tests/ps/build_autotune_fsbl.ps1`，使用当前Vivado生成的ps7_init.c，输出 `autotune_complete.sim/fsbl/autotune_fsbl.elf`。本次当前初始化文件与两个历史硬件平台逐字节SHA256一致；脚本不依赖2024年的FSBL二进制。原Xilinx pcap.c仍有一处未使用StatusReg变量告警，不影响链接。

## 本地启动镜像

完整硬件构建通过后执行 `./tests/ps/package_autotune.ps1`。脚本只读取 `autotune_complete.sim/hardware/` 的新bit、最终检查点、HDF硬件导出及报告，检查全局setup/hold/pulse-width及失败终点数，并拒绝旧于报告/源文件的bit；随后重建应用与FSBL，用Bootgen生成 `autotune_complete.sim/bootimage/BOOT_autotune.bin` 和带各启动组件、DCP、HDF及最终时序报告SHA256的manifest.json。默认Bootgen为SDK2018.3路径，可用 `-Bootgen` 指定。

此脚本不烧写设备，也不修改SDK原bootimage。打包前须完成 [硬件构建](../rtl/README.md) 的全部门槛，包括限定CDC例外、统计窗口检查和导出；时间戳检查用于拒绝意外的旧产物，不能替代这些设计验证或板级IO/动态验收。
