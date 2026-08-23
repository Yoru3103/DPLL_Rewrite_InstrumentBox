# DPLL 自适应调参与验证上位机

该程序对应 `DPLL_2COM_v2` 的 UART0 协议，默认串口参数为 921600、8N1。界面提供：

- 测频回路和锁相回路的中心频率寄存器读写。
- 两路 Kp、Ki、Kii、Kd 完整读取和写入。
- 锁相回路手动开启/关闭、测频回路复位。
- 0x97/0x98 自调命令的 START、QUERY、CANCEL、CLEAR 和 SET_POLICY。
- 自动轮询进度、RUN_ID、事务/健康状态、活动/最佳 profile 和评分。
- JSON 批次验证计划、重复运行以及 CSV/JSONL 双格式日志。

## 安装与启动

推荐使用 Python 3.10 或更高版本：

```powershell
cd host_app
python -m venv .venv
.venv\Scripts\python.exe -m pip install -r requirements.txt
.venv\Scripts\python.exe main.py
```

协议层单元测试不需要连接板卡：

```powershell
python -m unittest discover -s tests -v
```

## 数值单位

当前固件协议传输的是 PL 寄存器原始值，上位机不会擅自换算 Hz 或浮点 PID 系数。输入框支持十进制和带 `0x` 前缀的十六进制。这样可与现有命令保持完全一致，避免在尚未冻结量化换算公式时产生单位误解。

PID 写入始终发送 Kp/Ki/Kii/Kd 四个 uint32，小端排列。人工写 PID 时，固件会使该回路的 `PARAMS_VALID` 失效，之后需要重新运行 autotune 才能恢复 `ADAPT_READY`。

## 手动操作建议

1. 连接串口，先读取固件版本和两路当前参数。
2. 在“手动控制”页读取中心频率及 PID，保存屏幕记录。
3. 如需修改，输入全部四项 PID 后一次发送；不要只依据界面默认的 0 写入。
4. 确认目标回路已经开启并稳定锁定。
5. 在“Autotune”页保持 HOST_ONLY，先对测频回路 START。
6. 等待 DONE/FAILED，再启动锁相回路；固件全局仲裁器也会拒绝并行扫描。
7. CANCEL 后继续 QUERY，直到 BUSY 清零并进入 CANCELED/FAILED。

## 批次验证计划

“批次验证”页接受 JSON 数组。每个案例字段：

| 字段 | 必需 | 含义 |
|---|---|---|
| `name` | 是 | 案例名称 |
| `target` | 是 | `freq` 或 `dpll` |
| `repeat` | 否 | 重复次数，默认 1 |
| `center_frequency` | 否 | 写入的 uint32 原始值；`null` 表示不改 |
| `pid` | 否 | `[Kp, Ki, Kii, Kd]`；`null` 表示不改 |
| `autotune` | 否 | 是否执行自调，默认 true |
| `timeout_s` | 否 | 单次超时 |
| `note` | 否 | 输入幅值、频偏、扫频方式等实验条件说明 |

可从 [validation_plan.example.json](validation_plan.example.json) 开始修改。程序按顺序执行案例，不会并行启动两路。每次 QUERY 都写入日志，因此可以复核候选进度、评分、最终 profile 和 RUN_ID。

## 完整验证流程

### A. 通信和回退

1. 两路分别 QUERY，确认协议版本为 1。
2. 启动测频自调，同时尝试启动锁相自调，确认第二条返回 BUSY。
3. 在不同状态发送 CANCEL，确认最终恢复 ORIGINAL 且 BUSY 清零。
4. START 后检查 RUN_ID 递增，CLEAR 不改变 RUN_ID。

### B. 固定输入重复性

1. 固定中心频率、输入频率和输入幅值。
2. 每条回路至少重复 3 次。
3. 比较最佳 profile、最佳分数和完成时间；若最佳档频繁跳变，暂不进入幅值分档结论。

### C. 幅值分档

1. 对强、中、弱三个输入幅值分别建立案例，实际幅值写入 `note`。
2. 每个幅值至少重复 3 次，先测频后锁相。
3. 统计每档最常出现的最佳 profile、失败率和评分范围。
4. 任何限幅、残差越限或失锁案例单独保留日志，不与成功案例平均。

### D. 频率动态

1. 分别进行小频率阶跃、线性扫频和短时掉信号。
2. 当前默认扫描不启用 ACQUIRE；先用日志确认 TRACK 候选安全。
3. 需要测试 ACQUIRE 前，先根据实物结果修改方案文档，再开放代码入口。

### E. 结果固化

1. 汇总 CSV，按目标回路、幅值、profile 和结果分组。
2. 将稳定等待时间、评分窗口、幅值边界及最终候选值回写方案文档。
3. 文档评审后再修改固件表，不直接在代码中试改未记录参数。
