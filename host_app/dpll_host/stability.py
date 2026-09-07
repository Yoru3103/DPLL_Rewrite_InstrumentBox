"""Fixed-PID measurement sequence, independent of Qt and serial transport."""
from __future__ import annotations

import csv
import json
import math
import statistics
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from .protocol import (Command, ProtocolError, pack_pid, unpack_pid, unpack_ack,
                       unpack_u32, unpack_frequency, unpack_autotune)
from .validation import parse_int


DEFAULT_PROFILES = [
    {"name": "ORIGINAL", "pid": None},
    {"name": "SAFE", "pid": [0x200000, 0x40000, 0, 0]},
    {"name": "TRACK_WEAK", "pid": [0x200000, 0x80000, 0, 0]},
    {"name": "TRACK_MEDIUM", "pid": [0x300000, 0xC0000, 0, 0]},
    {"name": "TRACK_STRONG", "pid": [0x400000, 0x100000, 0, 0]},
]


def parse_profiles(text):
    rows = json.loads(text)
    if not isinstance(rows, list) or not 1 <= len(rows) <= 32:
        raise ValueError("需要 1～32 组 PID")
    result = []
    for row in rows:
        name = str(row["name"]).strip()
        if not name or name in [r[0] for r in result]:
            raise ValueError("参数组名称不能为空或重复")
        pid = row.get("pid")
        if pid is not None:
            if not isinstance(pid, list) or len(pid) != 4:
                raise ValueError("pid 必须包含 Kp/Ki/Kii/Kd 四项，null 表示原参数")
            pid = tuple(parse_int(v) for v in pid)
        result.append((name, pid))
    return result


def summarize(values, nominal_hz):
    if len(values) < 2 or not all(math.isfinite(v) for v in values):
        raise ValueError("至少需要两个有效频率样本")
    mean = statistics.mean(values)
    return dict(n=len(values), mean_hz=mean, std_hz=statistics.stdev(values),
                p2p_hz=max(values)-min(values), min_hz=min(values), max_hz=max(values),
                offset_hz=mean-nominal_hz)


def rank_results(rows, repeats):
    """Only fully measured groups qualify; do not concatenate repeat drift into jitter."""
    names = dict.fromkeys(r["name"] for r in rows)
    ranked = []
    for name in names:
        group = [r for r in rows if r["name"] == name]
        if len(group) != repeats:
            continue
        ranked.append(dict(name=name,
                           std_hz=math.sqrt(statistics.mean(r["std_hz"]**2 for r in group)),
                           p2p_hz=max(r["p2p_hz"] for r in group),
                           mean_hz=statistics.mean(r["mean_hz"] for r in group)))
    return sorted(ranked, key=lambda r: (r["std_hz"], r["p2p_hz"]))


@dataclass(frozen=True)
class Settings:
    settle_s: float = 3
    samples: int = 30
    repeats: int = 3
    nominal_hz: float = 40_000_000

    def validate(self):
        if not math.isfinite(self.settle_s) or not 0 <= self.settle_s <= 300:
            raise ValueError("稳定等待必须在 0～300 秒")
        if not 2 <= self.samples <= 3600 or not 1 <= self.repeats <= 20:
            raise ValueError("样本数 2～3600，重复次数 1～20")
        if not math.isfinite(self.nominal_hz) or self.nominal_hz <= 0:
            raise ValueError("标称频率必须为正数")


class Canceled(Exception):
    pass


class StabilityRun:
    """Generator yields (command, payload, delay_s); command=None means just wait.

    Caller feeds response bytes back using send(). Throwing an exception executes
    restoration. Transport loss must instead close logs and report unverified state.
    """
    GATE = 125_000_000  # one-second gate, matching the existing frequency decoder

    def __init__(self, profiles, settings, output_dir):
        settings.validate()
        self.profiles, self.settings = profiles, settings
        self.rows = []
        self.progress = "检查设备状态并保存原参数"
        self.restoring = False
        self.restored = False
        self.original = None
        self.original_gate = None
        self.changed = False
        folder = Path(output_dir)
        folder.mkdir(parents=True, exist_ok=True)
        stem = "pid_stability_" + datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        self.raw_path = folder / (stem + "_raw.csv")
        self.summary_path = folder / (stem + "_summary.csv")
        self.event_path = folder / (stem + ".jsonl")
        self.files = []
        try:
            for path in (self.raw_path, self.summary_path, self.event_path):
                self.files.append(path.open("x", encoding="utf-8-sig" if path.suffix == ".csv" else "utf-8", newline=""))
        except Exception:
            self.close()
            raise
        self.raw = csv.writer(self.files[0])
        self.summary = csv.writer(self.files[1])
        self.raw.writerow(["timestamp", "name", "repetition", "sample", "frequency_hz", "gate_clocks", "payload_hex"])
        self.summary.writerow(["name", "repetition", "pid", "n", "mean_hz", "std_hz", "p2p_hz", "min_hz", "max_hz", "offset_hz"])
        self.event("SETTINGS", profiles=profiles, settings=settings.__dict__)

    def event(self, event, **details):
        if event == "GROUP_START":
            self.progress = f"{details['name']} 第{details['repetition']}轮：写入参数并等待稳定"
        elif event == "SAMPLE":
            self.progress = (f"{details['name']} 第{details['repetition']}轮："
                             f"样本 {details['sample']}/{self.settings.samples}，{details['hz']:.6f} Hz")
        self.files[2].write(json.dumps(dict(timestamp=datetime.now().isoformat(), event=event, **details), ensure_ascii=False) + "\n")
        for f in self.files:
            f.flush()

    def close(self):
        for f in self.files:
            f.close()

    @staticmethod
    def locked(payload):
        if len(payload) != 7 or (payload[6] & 0x3F) != 0x30:
            raise ProtocolError("测频未锁定或存在限幅/残差越限，停止本批次")

    @staticmethod
    def busy(payload):
        if len(payload) != 1 or payload[0] not in (0, 1):
            raise ProtocolError("测频忙状态无效")
        return bool(payload[0])

    def sequence(self):
        # Prevent collision with a PS-autonomous task, including the other loop.
        for cmd in (Command.AUTOTUNE_FREQ, Command.AUTOTUNE_DPLL):
            status = unpack_autotune((yield cmd, b"\x00", 0))
            if status.busy:
                raise ProtocolError("PS Autotune 正忙，请先取消并等待结束")
        if self.busy((yield Command.READ_FREQ_RUN_STATUS, b"", 0)):
            raise ProtocolError("测频器正忙，请等待已有测量完成")
        self.original = unpack_pid((yield Command.READ_FREQ_PID, b"", 0))
        center = unpack_u32((yield Command.READ_FREQ_CENTER, b"", 0))
        self.original_gate = yield 0x16, b"", 0
        if len(self.original_gate) != 6:
            raise ProtocolError("原门宽读取长度错误")
        self.locked((yield Command.READ_FREQ_STATUS, b"", 0))
        self.event("ORIGINAL", pid=self.original, center_word=center,
                   gate_clocks=int.from_bytes(self.original_gate, "little"))
        abandoning = False
        try:
            self.changed = True  # mark before the write, including uncertain ACK cases
            unpack_ack((yield Command.WRITE_FREQ_TIMER, self.GATE.to_bytes(6, "little"), 0))
            if (yield 0x16, b"", 0) != self.GATE.to_bytes(6, "little"):
                raise ProtocolError("测量门宽读回不一致")
            # Interleave groups by repetition so each group is not confined to one time block.
            for repetition in range(1, self.settings.repeats + 1):
                for name, requested in self.profiles:
                    pid = self.original if requested is None else requested
                    self.event("GROUP_START", name=name, repetition=repetition, pid=pid)
                    unpack_ack((yield Command.WRITE_FREQ_PID, pack_pid(*pid), 0))
                    if unpack_pid((yield Command.READ_FREQ_PID, b"", 0)) != pid:
                        raise ProtocolError("PID 写入读回不一致")
                    yield None, b"", self.settings.settle_s
                    values = []
                    for sample in range(1, self.settings.samples + 1):
                        self.locked((yield Command.READ_FREQ_STATUS, b"", 0))
                        unpack_ack((yield Command.FREQ_TRIGGER, b"", 0))
                        deadline = time.monotonic() + 5
                        yield None, b"", 1.05
                        while self.busy((yield Command.READ_FREQ_RUN_STATUS, b"", 0)):
                            if time.monotonic() >= deadline:
                                raise ProtocolError("门宽测量超时")
                            yield None, b"", .1
                        payload = yield Command.READ_FREQ_COUNT, b"", 0
                        hz = unpack_frequency(payload)
                        if int.from_bytes(payload[10:], "little") != self.GATE:
                            raise ProtocolError("测量结果门宽与计划不一致")
                        # Preserve raw data even if the following lock check fails.
                        self.raw.writerow([datetime.now().isoformat(), name, repetition, sample, hz, self.GATE, payload.hex()])
                        self.event("SAMPLE", name=name, repetition=repetition, sample=sample, hz=hz)
                        self.locked((yield Command.READ_FREQ_STATUS, b"", 0))
                        values.append(hz)
                    stats = summarize(values, self.settings.nominal_hz)
                    row = dict(name=name, repetition=repetition, pid=pid, **stats)
                    self.rows.append(row)
                    self.summary.writerow([name, repetition, str(pid), *stats.values()])
                    self.event("GROUP_COMPLETE", **row)
        except GeneratorExit:
            abandoning = True
            raise
        finally:
            if self.changed and not abandoning:
                self.restoring = True
                self.event("RESTORE_BEGIN")
                # Let an already-triggered gate finish before restoring gate configuration.
                deadline = time.monotonic() + 5
                while self.busy((yield Command.READ_FREQ_RUN_STATUS, b"", 0)):
                    if time.monotonic() >= deadline:
                        raise ProtocolError("恢复时测频器仍忙，请人工恢复")
                    yield None, b"", .1
                unpack_ack((yield Command.WRITE_FREQ_PID, pack_pid(*self.original), 0))
                if unpack_pid((yield Command.READ_FREQ_PID, b"", 0)) != self.original:
                    raise ProtocolError("原 PID 恢复校验失败")
                unpack_ack((yield Command.WRITE_FREQ_TIMER, self.original_gate, 0))
                if (yield 0x16, b"", 0) != self.original_gate:
                    raise ProtocolError("原门宽恢复校验失败")
                self.restored = True
                self.event("RESTORED", pid=self.original)
