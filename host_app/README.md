# DPLL Autotune 与验证上位机

默认串口为 921600、8N1。支持两路中心频率、完整 PID、启停控制，以及 PS Autotune、批次验证、固定 PID 稳定度实验。

## 安装和启动

```powershell
cd host_app
python -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
.venv\Scripts\python.exe main.py
```

离线协议与 GUI 测试，无需连接板卡：

```powershell
.venv\Scripts\python.exe -m unittest discover -s tests -v
```

## 完整 PS Autotune（协议 v2）

本次整定由 PS 自主完成，PL 提供窗口统计，上位机负责配置、显示与日志。规则以 [AUTOTUNE_COMPLETE_DESIGN.md](../AUTOTUNE_COMPLETE_DESIGN.md) 和 [PID_EVALUATION_RULES.md](../PID_EVALUATION_RULES.md) 为准。

1. 连接串口，在手动控制页读回中心频率与 PID，确认输入信号有效、目标回路已开启并锁定。
2. 打开 Autotune 页。QUERY 会识别协议版本；v2 才启用对应回路的配置/指标子页。v1 保留旧控制和状态，自动诊断不会向旧固件发送新命令。
3. 按需读取或修改窗口时间、重复次数、覆盖率、幅值底限和最小改善。点击“提交配置并读回”后，只有提交成功且五项读回完全一致才显示成功。配置在PS内存中生效并使之前的PARAMS_VALID失效，须重新整定验证新规则；界面未读设备前的数值只是工程默认值。
4. 保持 HOST_ONLY，点击一个回路的 START。PS 会执行校准、正式基线、候选重复测量、ORIGINAL 控制复测和最终复验。另一条回路不能同时整定。
5. 等待 DONE 或 FAILED；CANCEL 发出后继续等 BUSY 清零。SUCCESS 表示最佳候选复验通过，NO_IMPROVEMENT 表示 ORIGINAL 复验通过且保留原参数。

当前仅实现 HOST_ONLY；界面不提供 BOOT_ONCE/BOOT_AND_RECOVER，以免误认为存在自动启动或恢复调参功能。缺少新参数/统计硬件接口会返回 UNSUPPORTED。ROLLBACK_FAILED 表示原参数恢复或重新锁定未通过，需要检查板卡状态。

默认每轮 1000 ms、重复 3 次、覆盖率下限 800‰、幅值底限 16 raw、最小改善 30‰。窗口允许 1000～2000 ms，重复 2～5 次，两者乘积不得超过 6000 ms；覆盖率 800～1000‰，幅值底限 1～65535 raw，最小改善 1～500‰。整定运行时配置写入被禁用，固件也会再次检查全局忙状态。

v2 状态中的 16 位分数按 J×1000 编码，界面显示除以 1000 的值；65535 表示尚无合格分数或已饱和，应查看完整诊断中的有效位与浮点分数。v1 分数仍按旧整数原样显示。

## 指标显示与 JSONL

开启自动查询后，状态每 250 ms 查询，诊断最多每秒启动一批；优先读取正在整定的回路。每批依次读取 0～8 页，page0 冻结整份报告，后续请求完成上一页后才发送。版本、action、页序、RUN_ID、REPORT_ID、模式、候选、轮次、有效位必须一致；缺页、混页、非有限浮点数均丢弃，不拼凑成完整报告。

每条 JSONL 保存一份完整报告，包括否决原因、全部指标、归一化尺度、配置、实际 PID、时钟与输出边界、有效位及九页原始十六进制内容。按回路、RUN_ID、REPORT_ID 去重，写入后立即 flush。默认目录 `host_app/validation_logs`，可在 Autotune 页修改（新日志文件创建时生效）；断连后关闭文件并清除能力、批次和去重状态。日志目录不提交 Git。

固件只提供最新报告，上位机日志是低频轮询快照，不保证保存每一轮；PS独立评价其收到且通过覆盖检查的窗口，不依赖主机日志完整性。固定 PID 实验和批次验证期间暂停独立诊断，不向其串口序列插入扩展请求。批次验证自身保存状态 CSV/JSONL。

| 页 | 冻结报告字段（每页 8×32 位） |
|---|---|
| 0，uint32 | 否决位、窗口数、缺窗数、有效符号对、翻转次数、读取错误、耗时 ms、样本数低 32 位 |
| 1，uint32 | 样本数高 32 位、首/末序号、失锁/正限幅/负限幅事件、提交错误、幅值最小值 |
| 2，float32 | 频率 mean/RMS/std/MAE/peak；相位 mean/MAE/peak |
| 3，float32 | 平均绝对相位斜率、斜率有效比例、翻转率、窗口频差绝对均值、幅值均值、时间覆盖率、锁定比例、任一残差越限比例 |
| 4，float32 | 限幅比例、相位饱和比例、输出余量、J、频率/相位各自越限比例、归一化 F/P |
| 5，uint32 | 幅值最大值、有符号输出最小/最大值、Kp/Ki/Kii/Kd/D_COEF |
| 6，float32 | 归一化 D、死区、组均分/极差、基线均分/极差、最佳均分/极差 |
| 7，uint32 | 五项配置、时钟 Hz、窗口样本数、稳定等待 ms |
| 8，混合 | phaseOffset/outputLow/outputHigh 为 int32；groupSize/bestProfile 为 uint32，其余保留 |

频率残差、相位残差、幅值、控制输出均为 raw；相位斜率为 raw/s，样本比例为0～1；时间覆盖率因毫秒计时量化允许到1.05，超出即视为异常。频率 raw 不是 Hz，不能直接与门宽测频输出混用。没有相位平方和，因此不显示不存在的相位 RMS。有效位分别说明该轮是否合格、翻转率是否可用、斜率是否可用；groupSize=0 表示尚未形成完整重复组，不能把组均分零解释为最优结果。

协议保持 0x97/0x98、action0～4 与 18 字节状态；v2 新增 action5 `[5,page]`（44 字节返回）、action6 `[6]`（24 字节配置）和 action7 `[7]+5×uint32LE`（18 字节状态后读回）。新结果码为 10 UNSUPPORTED、11 DATA_ERROR、12 NO_IMPROVEMENT、13 INPUT_CHANGED、14 VERIFY_FAILED、15 TIMEOUT、16 ROLLBACK_FAILED、17 BAD_CONFIG。

## 数值单位与手动测频

中心频率输入为 MHz（例如 `40`、`40MHz`、`40.5`），按 `round(MHz × 2^32 / 125)` 转换为 uint32 控制字；读回显示九位小数。PID 为原始 uint32，支持十进制和 `0x` 前缀，每次写入全部 Kp/Ki/Kii/Kd。手动写 PID 会使 PARAMS_VALID 失效，需要重新整定才能建立 ADAPT_READY。

测频回路的“读取实时频率”设置 125000000 时钟的门宽并触发一次测量，约需一秒。结果是测频回路跟踪频率的门宽平均值，依照当前 125 MHz 时钟和 33 位相位比例换算：`Hz = 80位累计值 × 125000000 / 门宽时钟数 / 2^33`。使用前应保证回路锁定。此操作会修改门宽，整定运行时固件拒绝冲突命令。

## 批次验证

JSON 计划字段：`name`、`target`（freq/dpll）、`repeat`（默认1）、`center_frequency`（uint32 控制字或 null）、`pid`（四个 uint32 或 null）、`autotune`（默认 true）、`timeout_s`（默认150秒）、`note`。参见 [validation_plan.example.json](validation_plan.example.json)。

批次顺序执行，每次查询记录状态 CSV/JSONL。运行期间其他操作与独立诊断暂停。START 被拒绝会立即记录失败；用户停止、超时或串口请求错误会终止后续案例并发出 CANCEL，等待 BUSY 清零再结束。取消/回退在额外十秒内未确认时终止批次并报告未知设备状态，不自动开始下一案例。断连时应重新连接并 QUERY 确认状态。

## 固定 PID 稳定度实验

该页独立比较固定 PID 下的 1 秒门宽测频波动，不发送 Autotune START，不自动应用排名第一的参数。默认 ORIGINAL 与四组现有测频候选，每组等待3秒、采30点、交错重复3轮。`pid=null` 使用批次开始保存的原 PID；可在 JSON 中调整候选。

上位机计算频率均值、标准差、峰峰值；按各轮标准差 RMS 排序、最大峰峰值辅助。此标准差 RMS 是各轮标准差的合成量，与 PS 的频率残差 RMS 定义不同。零分或近似并列不能证明显著改善。

运行中保存 raw.csv、summary.csv 和事件 JSONL，结束/停止/错误时尝试恢复原 PID 与门宽并核对；恢复读回不代表已重新锁定。断连须人工确认。仅适用于测频回路，不能替代 DPLL 输出或板上动态性能验证。
