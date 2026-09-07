# DPLL 自适应调参执行方案

> 文档状态：执行稿 v0.8
>
> PS 基线：`DPLL_2COM_v2`
>
> FPGA 工程：Vivado 2018.3
>
> 更新日期：2026-09-07

## 1. 项目目标

项目包含两条独立闭环：

| 回路 | 时钟 | 主要用途 |
|---|---:|---|
| 测频回路 | 125 MHz | 频率测量与频率跟踪 |
| 锁相回路 | 3.125 MHz | 锁相追踪与输出控制 |

升级目标是在保留原有手动控制功能的基础上，由 PS 根据输入幅值、频率残差、相位残差、锁定状态和限幅情况选择合适的参数档，并安全更新完整 PID 参数组。

## 2. 已确认原则

1. 两条回路分别调参，使用独立命令、上下文、状态和参数表。
2. 上位机只负责发起任务、查询状态、手动控制和保存日志；自调流程由 PS 执行。
3. 测频回路使用命令 `0x97`，锁相回路使用命令 `0x98`。
4. 完成标志由 PS 维护，上位机通过 UART 查询，不依赖持续阻塞等待。
5. 参数采用离散 profile，不进行无限制的在线连续搜索。
6. 任何失败、取消或验证不通过都必须回退到已知可用参数。
7. 原有参数地址和手动 PID、中心频率控制继续保留。
8. 所有设计变化先修改本文档，再修改代码。

## 3. 总体架构

```text
上位机
  ├─ 手动设置 PID/中心频率
  ├─ 发送 0x97 或 0x98
  ├─ 查询进度和结果
  └─ 保存测试日志
          ↓ UART
PS（决策与状态机）
  ├─ 双回路独立上下文
  ├─ 采集质量指标
  ├─ 选择参数 profile
  ├─ 执行提交与回退
  └─ 维护 BUSY/DONE/FAILED/RUN_ID
          ↓ 寄存器总线
PL（观测与安全执行）
  ├─ 一致统计快照
  ├─ shadow 参数
  ├─ 原子 commit/ack
  └─ 旧接口兼容
```

同一时刻只允许一条回路执行自调，另一条命令仍可查询，但不能同时启动新的参数扫描。

## 4. 通信和运行方式

两条命令均支持：

- `QUERY`：查询当前任务、进度、结果和 RUN_ID。
- `START`：启动目标回路的自调任务。
- `CANCEL`：取消任务并回退。
- `CLEAR`：清除已完成或失败状态。
- `SET_POLICY`：设置启动策略。

运行策略：

| 策略 | 行为 | 当前使用情况 |
|---|---|---|
| HOST_ONLY | 仅上位机发送 START 时运行 | 当前默认 |
| BOOT_ONCE | 开机后自动运行一次 | 后续启用 |
| BOOT_AND_RECOVER | 开机运行，并在确认失锁后申请重调 | 最终目标 |

UART 处理必须保持非阻塞。自调状态机由主循环周期推进，不能在命令回调中长时间采样或等待锁定。

### 4.1 串口与通用帧格式

上位机使用 PS UART0 通信，参数为 `921600 baud、8 data bits、no parity、1 stop bit`。

| 字节偏移 | 请求帧 | 响应帧 | 说明 |
|---:|---:|---:|---|
| 0 | `0xC6` | `0xA2` | 帧头 |
| 1 | `CHECKSUM` | `CHECKSUM` | 从 `CMD` 到最后一个 payload 字节的累加和低 8 bit |
| 2 | `CMD` | `CMD` | 命令字，响应通常回显请求命令 |
| 3 | `LEN` | `LEN` | payload 字节数 |
| 4～ | `PAYLOAD` | `PAYLOAD` | 命令参数或返回数据 |

所有多字节整数均使用小端序。PS 当前接收缓冲检查要求完整请求帧不超过 48 字节，因此上位机发送 payload 应限制在 44 字节以内；现有命令最大 payload 为 16 字节。

请求校验计算式：

```text
CHECKSUM = (CMD + LEN + sum(PAYLOAD)) & 0xFF
```

例如，启动测频回路自调的完整发送帧为 `C6 99 97 01 01`；查询锁相回路自调状态的发送帧为 `C6 99 98 01 00`。

### 4.2 当前上位机命令表

| CMD | 方向 | 请求 payload | 响应 payload | 功能 |
|---:|---|---|---|---|
| `0x03` | 读 | 无 | `center:u32` | 读取锁相回路中心频率 |
| `0x07` | 读 | 无 | `Kp,Ki,Kii,Kd`，各 `u32` | 读取锁相回路当前实际生效 PID |
| `0x09` | 读 | 无 | 输出、相位残差、瞬时频率、状态 | 读取锁相回路运行状态 |
| `0x0A` | 读 | 无 | `version:u8` | 读取 PS 协议/程序版本 |
| `0x10` | 读 | 无 | `center:u32` | 读取测频回路中心频率 |
| `0x13` | 读 | 无 | `Kp,Ki,Kii,Kd`，各 `u32` | 读取测频回路当前实际生效 PID |
| `0x14` | 读 | 无 | 相位残差、瞬时频率、状态 | 读取测频回路运行状态 |
| `0x82` | 写 | `center:u32` | `ACK:u8` | 设置锁相回路中心频率 |
| `0x86` | 写 | `Kp,Ki,Kii,Kd`，各 `u32` | `ACK:u8` | 手动设置锁相回路 PID |
| `0x8A` | 写 | 无 | `ACK:u8` | 开启锁相回路 |
| `0x8B` | 写 | 无 | `ACK:u8` | 关闭锁相回路 |
| `0x90` | 写 | `center:u32` | `ACK:u8` | 设置测频回路中心频率 |
| `0x93` | 写 | `Kp,Ki,Kii,Kd`，各 `u32` | `ACK:u8` | 手动设置测频回路 PID |
| `0x96` | 写 | 无 | `ACK:u8` | 复位并重新开启测频回路 |
| `0x97` | 双向 | 自调 action | 18 字节自调状态 | 控制或查询测频回路自调 |
| `0x98` | 双向 | 自调 action | 18 字节自调状态 | 控制或查询锁相回路自调 |

普通写命令的 `ACK=0` 表示接受成功，非零值表示设备拒绝或执行错误。

### 4.3 自调命令 payload

`0x97` 和 `0x98` 使用同一套 payload：

| Action | 请求 payload | 功能 |
|---:|---|---|
| `0x00 QUERY` | `00` | 查询当前状态，不改变任务 |
| `0x01 START` | `01` | 启动目标回路自调 |
| `0x02 CANCEL` | `02` | 请求取消，状态机随后回退 ORIGINAL |
| `0x03 CLEAR` | `03` | 空闲时清除 DONE/FAILED 和历史结果 |
| `0x04 SET_POLICY` | `04 policy` | 设置策略：`0=HOST_ONLY`、`1=BOOT_ONCE`、`2=BOOT_AND_RECOVER` |

当前正式使用策略仍为 `HOST_ONLY`。`BOOT_ONCE` 和 `BOOT_AND_RECOVER` 只保留协议入口，需完成后续验证后启用。

### 4.4 自调响应 payload

`0x97/0x98` 固定返回 18 字节 payload：

| payload 偏移 | 长度 | 字段 | 说明 |
|---:|---:|---|---|
| 0 | 1 | `protocol_version` | 当前为 1 |
| 1 | 1 | `action` | 本次响应对应的 action |
| 2 | 4 | `status_word` | 状态位，小端序 |
| 6 | 1 | `progress` | 进度 0～100 |
| 7 | 1 | `current_profile` | 当前正在评价的 profile ID |
| 8 | 1 | `active_profile` | 当前硬件生效的 profile ID |
| 9 | 1 | `best_profile` | 当前最佳 profile ID |
| 10 | 2 | `current_score` | 当前评分，饱和到 `0xFFFF` |
| 12 | 2 | `best_score` | 最佳评分，饱和到 `0xFFFF` |
| 14 | 4 | `elapsed_ms` | 本次任务运行时间，小端序 |

`status_word` 定义：

| 位 | 含义 |
|---:|---|
| 0 | `DONE`，任务正常完成 |
| 1 | `BUSY`，任务正在运行 |
| 2 | `FAILED`，任务失败 |
| 3 | `PARAMS_VALID`，当前参数已通过验证 |
| 4 | `LOCK_VALID`，当前锁定状态有效 |
| 5 | `RETUNE_PENDING`，存在重调申请 |
| 6 | 已启用失锁恢复策略 |
| 7 | 已启用非 HOST_ONLY 自动策略 |
| 8～11 | 执行状态 `execState` |
| 12～15 | 健康状态 `healthState` |
| 16～23 | 结果码 `result` |
| 24～31 | `runId`，用于区分不同自调任务 |

响应枚举值对照：

| 字段 | 数值定义 |
|---|---|
| `execState` | `0 IDLE`、`1 PRECHECK`、`2 BASELINE`、`3 APPLY_CANDIDATE`、`4 SETTLE`、`5 EVALUATE`、`6 NEXT_CANDIDATE`、`7 SELECT_BEST`、`8 APPLY_BEST`、`9 VERIFY`、`10 ROLLBACK`、`11 DONE`、`12 FAILED`、`13 CANCELED` |
| `healthState` | `0 UNINITIALIZED`、`1 VALID`、`2 DEGRADED`、`3 LOST`、`4 RETUNE_PENDING`、`5 FAULT` |
| `result` | `0 NONE`、`1 SUCCESS`、`2 ACCEPTED`、`3 BUSY`、`4 REJECTED`、`5 INVALID_ACTION`、`6 INVALID_POLICY`、`7 NOT_LOCKED`、`8 READBACK_ERROR`、`9 CANCELED` |
| `profile ID` | `0 ORIGINAL`、`1 SAFE`、`2 TRACK_WEAK`、`3 TRACK_MEDIUM`、`4 TRACK_STRONG`、`5 ACQUIRE`、`0xFF NONE` |

上位机判断自调可用应同时检查 `DONE=1`、`PARAMS_VALID=1` 和 `LOCK_VALID=1`，不能只检查历史 DONE 位。

## 5. 参数选择策略

每条回路分别维护以下 profile：

- `ORIGINAL`：任务开始时读取的原参数，用于基线和最终回退。
- `SAFE`：低增益安全参数。
- `TRACK_WEAK`：弱信号窄带跟踪参数。
- `TRACK_MEDIUM`：中等信号参数。
- `TRACK_STRONG`：强信号参数。
- `ACQUIRE`：用于捕获或较大频率变化，默认不参与普通扫描。

当前阶段优先调整 Kp、Ki。Kii、Kd 和 D 滤波系数只有在单独完成稳定性验证后才开放自动调整。

阶段 2 的候选数值保留在当前 PS 代码中，但本轮实测结果暂不作为最终参数标定结论。未来修改 profile 数值时仍需先更新文档。

## 6. 观测与决策指标

完整定义见 [PID_EVALUATION_RULES.md](PID_EVALUATION_RULES.md)，分阶段交付见 [AUTOTUNE_IMPLEMENTATION_PLAN.md](AUTOTUNE_IMPLEMENTATION_PLAN.md)。

现行 PS 评分只使用平均绝对频率/相位残差及失锁、限幅、越限计数；幅值用于合格性。峰值、输出范围和事件字段不等于已经参与选参，重新锁定时间目前也不是独立评分项。

阶段 5A 增加频率有符号和/平方和、相位有符号和/首末值、精确 OR 计数和相位饱和计数，提供 PS 计算基础。后续依次实现窗口覆盖与诊断、新评价/重复搜索、动态验收。RMS、相位趋势和翻转率尚不参与现行评分。

目标规则分为数据有效性、输入可比性、安全合格性和性能比较；不把所有相关指标直接相加。相位残差是会饱和和清零的累加器，趋势解释需排除饱和与切换窗口。

## 7. PS 状态语义

一次自调事务至少包含以下阶段：

```text
IDLE → PRECHECK → BASELINE → APPLY → SETTLE
     → EVALUATE → SELECT_BEST → VERIFY → DONE
```

异常路径统一进入：

```text
ROLLBACK → FAILED / CANCELED
```

关键状态含义：

- `BUSY`：任务正在执行。
- `DONE`：本次任务已经正常结束。
- `FAILED`：任务失败，参数已经回退或正在回退。
- `RUN_ID`：区分不同任务，避免上位机把旧响应当成新结果。
- `ADAPT_READY`：至少有一组参数完成最终验证。
- `LOCK_VALID`：当前仍满足锁定条件；它与历史 DONE 状态分开维护。

## 8. 安全和兼容要求

1. 自动模式必须按完整参数组提交，禁止锁定状态下逐寄存器写入半组新参数。
2. 锁相回路的参数和统计跨时钟域必须使用明确的握手或快照机制。
3. commit 只有在 ack 和 active 参数读回一致后才算成功。
4. 上电默认继续使用 legacy 参数路径；首次原子提交成功后才进入 atomic mode。
5. 再次写旧参数地址时退出 atomic mode，保持原有手动功能可用。
6. 自动调参期间禁止其它命令修改目标回路的 PID、锁定开关和中心频率。
7. 失去输入信号时保持安全输出，不在噪声上反复搜索参数。

## 9. 当前阶段状态

| 阶段 | 内容 | 状态 |
|---:|---|---|
| 0 | 原系统与 PS v2 基线 | 已完成，不再重复验证 |
| 1 | 双 UART 异步命令、状态机和完成标志 | 已完成 |
| 2 | 方案 B 参数扫描与 Python 上位机 | 用户确认本阶段结束；实测结果暂不采用 |
| 3 | PL 统计快照、原子提交、CDC 和 PS HAL | 已提交，完整工程实现与板上验收待执行 |
| 4 | PS 状态机接入方案 C 接口 | 代码已完成，待 SDK 完整构建与上板验证 |
| 5A | 扩展观测量、HAL 和指标计算 | 实施与验证见新计划 |
| 5B/5C | PS 窗口诊断、新评价和重复选参 | 待实施 |
| 5D | 动态响应及完整工程/板上验收 | 待实施 |
| 6 | Kii、Kd、温漂和更高级策略 | 未来扩展 |

阶段 3 的模块职责见 [ADAPTIVE_DPLL_STAGE3_MODULES.md](ADAPTIVE_DPLL_STAGE3_MODULES.md)。阶段 4 的接入边界见 [ADAPTIVE_DPLL_STAGE4_PS_INTEGRATION.md](ADAPTIVE_DPLL_STAGE4_PS_INTEGRATION.md)。

## 10. 验收要求

### 软件与通信

- `0x97`、`0x98` 可分别启动、取消和查询。
- UART 在自调期间保持响应。
- DONE、FAILED、RUN_ID 和回退结果语义正确。
- Python 上位机可以手动控制、运行自调和保存日志。

### FPGA 接口

- 两条回路的统计数据来自完整一致窗口。
- 随机时钟相位下 commit 不丢失、不重复。
- busy 或重复 sequence 不覆盖活动参数。
- legacy 参数地址仍可正常工作。
- 完整工程综合、实现、时序和 CDC 报告通过。

### 板上运行

- 原有固定参数功能不受影响。
- 参数切换失败时能够恢复 ORIGINAL。
- 不同幅值、频偏和掉信号场景下无危险输出或持续限幅。
- BOOT_ONCE 和自动恢复只能在 HOST_ONLY 验证稳定后启用。

## 11. 文档维护规则

固定 PID 门宽测频稳定度保持独立；方案见 [STABILITY_TEST_PLAN.md](STABILITY_TEST_PLAN.md)。

- 本文档只保存目标、决策、阶段状态和验收规则。
- 模块职责与接口概览保存在阶段模块文档。
- 具体参数数值以代码和测试日志为准；数值冻结前先修改文档。
- 调试过程、备选方案和已淘汰设计不继续堆叠到核心文档，可通过 Git 历史查看。
