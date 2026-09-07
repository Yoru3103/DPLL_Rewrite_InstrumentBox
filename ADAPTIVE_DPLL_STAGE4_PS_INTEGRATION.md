> 历史阶段记录：后续阶段 5A 扩展及当前状态见 [AUTOTUNE_IMPLEMENTATION_PLAN.md](AUTOTUNE_IMPLEMENTATION_PLAN.md)。下述“尚未接入”“保持不变”描述该历史阶段边界。

<!--
 * @Author: WZX
 * @Date: 2026-08-29 23:47:34
 * @LastEditors: 
 * @LastEditTime: 2026-09-01 20:48:03
 * @Description: 请填写简介
-->
# 阶段 4：PS 接入方案 C

> 本阶段先完成 PS 状态机对统计快照和原子提交接口的接入，不启用开机自动调参和失锁自动恢复。

当前状态：代码已完成 ARM GCC 静态编译检查，等待 SDK 刷新工程后的完整构建与上板验证。

## 1. 实施目标

1. `0x97/0x98` 保持现有命令格式和上位机兼容性。
2. 检测到阶段 3 PL 接口时，使用硬件统计快照评价候选参数。
3. 参数更新改用 shadow + commit + applied sequence 确认。
4. 未检测到阶段 3 接口时，保留方案 B 作为兼容回退路径。
5. 当前策略继续固定为 HOST_ONLY。

## 2. 运行路径

初始化时分别探测测频和锁相回路的 `ADAPT_IF_INFO`：

```text
接口存在 → Scheme C 快照采集 + 原子提交
接口不存在 → Scheme B 瞬时寄存器采集 + legacy 参数写入
```

两条回路独立保存：

- PL 接口是否可用。
- 最近处理的快照序号。
- 下一次参数提交序号。
- 当前活动 profile。

## 3. 统计快照接入

BASELINE、EVALUATE 和 VERIFY 阶段不再把每次 PS 轮询当作一个样本。Scheme C 下每次只接收新的 `snapshot_seq`（收到重复的snapshot_seq就跳过），并将完整 PL 窗口合并到当前评价指标。

评价时间、评分公式和安全门限保持不变，避免同时改变数据源与决策规则。Scheme B 回退路径继续使用原有低速瞬时采样。

进入新的评价状态时先记录当前快照序号，防止把参数切换前的旧窗口计入新候选。

## 4. 参数提交接入

Scheme C 参数更新顺序：

```text
保存 manual offset（）
→ 关闭目标回路 lock
→ 写 profile ID 和完整 shadow 参数
→ 写新的 COMMIT_SEQ
→ 等待 APPLIED_SEQ 并校验 active 参数
→ 恢复 manual offset
→ 重新打开目标回路 lock
```

阶段 3 的 commit 仍会产生一次 `gain_changed`，因此本阶段继续受控解锁后提交，不声明为无扰在线切换。参数 ramp 或保持积分状态属于后续子阶段。

提交超时、接口错误或 active 参数不一致时进入原有 ROLLBACK/FAILED 路径。

## 5. 兼容性

- UART 协议版本和回复长度不变。
- Python 上位机不需要同步修改即可运行。
- 原 PID 查询命令格式不变；atomic mode 下返回 active 参数，legacy mode 下返回旧地址参数。
- 手动 PID 写入继续走旧地址，并会使 PL 退出 atomic mode。
- 自调任务开始时根据 PL 当前模式读取真实活动参数，确保 ORIGINAL 可以正确回退。
- Scheme C 不可用时自动使用 Scheme B，不影响旧 bitstream。

## 6. 本阶段不做

- 不启用 BOOT_ONCE。
- 不启用 BOOT_AND_RECOVER。
- 不增加自动失锁重调。
- 不修改候选参数数值和评分权重。
- 不实现参数 ramp。
- 不开放 Kii、Kd 的在线搜索。

## 7. 验证要求

- PS HAL 和主程序通过 ARM GCC 构建。
- Scheme C 快照不会重复累计，同一评价阶段至少获得规定数量的有效样本。
- 两条回路原子提交后 active 参数与目标 profile 一致。
- 取消、失败和最终验证不通过均能恢复 ORIGINAL。
- 阶段 3 接口缺失时 Scheme B 路径仍可运行。
- UART 自调和手动命令格式保持兼容。
