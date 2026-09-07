> 历史阶段记录：后续阶段 5A 扩展及当前状态见 [AUTOTUNE_IMPLEMENTATION_PLAN.md](AUTOTUNE_IMPLEMENTATION_PLAN.md)。下述“尚未接入”“保持不变”描述该历史阶段边界。

# 阶段 3：PL 安全接口与未来规划

> 本文档只说明模块目的、接口分区和后续接入方向。RTL 细节以源码注释和测试文件为准。

## 1. 阶段目的

阶段 3 为两条环路提供统一的安全底座：

- PL 形成完整、可重复读取的统计窗口。
- PS 先写 shadow 参数，再一次性提交整组参数。
- 测频回路在 125 MHz 同域应用参数。
- 锁相回路通过 request/ack 跨到 3.125 MHz 域应用参数。
- 旧参数地址继续保留，方便手动控制和回退。

本阶段不启用在线参数调度，也不实现参数渐变。现有 `0x97/0x98` 状态机仍按方案 B 执行，切换到新接口属于阶段 4。

## 2. RTL 模块

| 模块 | 目的 |
|---|---|
| `adaptive_statistics.v` | 按固定窗口统计幅值、残差、输出范围和状态事件 |
| `adaptive_snapshot_cdc.v` | 将 3.125 MHz 域的整组统计快照送到 125 MHz 总线域 |
| `adaptive_param_commit_same_clock.v` | 测频回路同域 shadow/commit 和 legacy 兼容 |
| `adaptive_param_commit_cdc.v` | 锁相回路跨时钟 request/ack、原子参数应用和 legacy 兼容 |

顶层接入位置：

- `Freq_Meter/Digital_Freq_Meter.v`
- `DigitalPLL/dpll_wrapper.v`

## 3. 统计窗口

| 回路 | 时钟 | 样本数 | 窗口时间 |
|---|---:|---:|---:|
| 测频 | 125 MHz | 131072 | 约 1.049 ms |
| 锁相 | 3.125 MHz | 4096 | 约 1.311 ms |

每个窗口提供：

- 幅值累加和及极值。
- 频率残差绝对值累加和及峰值。
- 相位残差绝对值累加和及峰值。
- 环路输出极值。
- 锁定、限幅和残差越限样本数。
- 失锁及限幅事件计数。
- 快照序号和样本数。

均值和评分由 PS 计算，PL 不增加除法和 RMS 运算。

## 4. 参数提交接口

两条回路使用相同 word address，分别叠加各自基地址：

- 测频基地址：`0x40200000`
- 锁相基地址：`0x40600000`

| Word 地址范围 | 用途 |
|---:|---|
| `0x0060` | 接口标识 `0xAD030001` |
| `0x0061～0x0066` | shadow profile、Kp、Ki、Kii、Kd、D_COEF |
| `0x0067` | COMMIT_SEQ |
| `0x0068～0x0069` | APPLIED_SEQ 和提交状态 |
| `0x006A～0x006F` | 当前活动 profile 和参数组 |
| `0x0120～0x0135` | 统计快照和事件计数 |

PS 提交流程：

```text
检查接口 → 等待非 busy → 写 shadow 参数 → 写新 sequence
→ 等待 applied sequence → 校验 active 参数
```

## 5. PS 接口

`DPLL_2COM_v2/src/AdaptivePlIf.c/.h` 提供：

- 接口版本探测。
- 参数组提交、超时等待和活动参数校验。
- sequence-before/after 一致快照读取。

当前 HAL 已实现，但尚未接入现有候选扫描状态机。

## 6. 已完成验证

- Vivado 2018.3 RTL 解析通过。
- 同域和跨时钟参数提交自检通过。
- busy、重复 sequence 和 legacy 回退自检通过。
- 窗口统计与快照 CDC 自检通过。
- 统计模块独立综合通过，未使用 DSP。
- PS HAL 通过 ARM GCC C99 语法检查。

完整工程的综合、实现、时序、CDC 报告和板上测试仍需在工程评审后执行。

## 7. 下一阶段规划

阶段 4：

1. 将 `0x97/0x98` 状态机的数据采集切换到 PL 统计快照。
2. 将候选参数写入切换到原子 commit/ack。
3. 保留方案 B 回退路径，确认新 bitstream 和接口版本后才使用方案 C。
4. 先启用 HOST_ONLY，再测试 BOOT_ONCE。
5. 增加 VALID、DEGRADED、LOST、RETUNE_PENDING 和 HOLDOVER 判断。
6. 评估参数渐变或 PS 小步原子更新，降低切换冲击。

更远期规划：

- 单独评估 Kii。
- 单独评估 Kd 和 D 滤波系数。
- 根据频段、温度或硬件差异选择 profile。
- 在稳定离散调度基础上再考虑受限在线微调。
