from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime
import csv
import json
from pathlib import Path
from typing import Any

from .protocol import LoopTarget


DEFAULT_PLAN = [
    {
        "name": "freq_baseline_scan",
        "target": "freq",
        "repeat": 3,
        "center_frequency": None,
        "pid": None,
        "autotune": True,
        "timeout_s": 150,
        "note": "保持当前输入条件，重复验证测频候选选择的一致性"
    },
    {
        "name": "dpll_baseline_scan",
        "target": "dpll",
        "repeat": 3,
        "center_frequency": None,
        "pid": None,
        "autotune": True,
        "timeout_s": 150,
        "note": "保持当前输入条件，重复验证锁相候选选择的一致性"
    }
]


@dataclass(frozen=True)
class ValidationCase:
    name: str
    target: LoopTarget
    repeat: int = 1
    center_frequency: int | None = None
    pid: tuple[int, int, int, int] | None = None
    autotune: bool = True
    timeout_s: float = 150.0
    note: str = ""

    @staticmethod
    def from_dict(data: dict[str, Any]) -> "ValidationCase":
        target_name = str(data["target"]).lower()
        if target_name not in {"freq", "dpll"}:
            raise ValueError(f"target 必须是 freq 或 dpll: {target_name}")
        repeat = int(data.get("repeat", 1))
        if repeat < 1:
            raise ValueError("repeat 必须大于等于 1")
        center = data.get("center_frequency")
        center = None if center is None else parse_int(center)
        raw_pid = data.get("pid")
        pid = None if raw_pid is None else tuple(parse_int(item) for item in raw_pid)
        if pid is not None and len(pid) != 4:
            raise ValueError("pid 必须包含 Kp/Ki/Kii/Kd 四项")
        return ValidationCase(
            name=str(data["name"]),
            target=LoopTarget.FREQ if target_name == "freq" else LoopTarget.DPLL,
            repeat=repeat,
            center_frequency=center,
            pid=pid,
            autotune=bool(data.get("autotune", True)),
            timeout_s=float(data.get("timeout_s", 150.0)),
            note=str(data.get("note", "")),
        )


def parse_int(value: Any) -> int:
    number = int(value, 0) if isinstance(value, str) else int(value)
    if not 0 <= number <= 0xFFFFFFFF:
        raise ValueError(f"数值超出 uint32: {value}")
    return number


def parse_plan(text: str) -> list[ValidationCase]:
    raw = json.loads(text)
    if not isinstance(raw, list) or not raw:
        raise ValueError("验证计划必须是非空 JSON 数组")
    return [ValidationCase.from_dict(item) for item in raw]


def default_plan_text() -> str:
    return json.dumps(DEFAULT_PLAN, ensure_ascii=False, indent=2)


@dataclass
class RunRecord:
    timestamp: str
    case_name: str
    target: str
    repetition: int
    event: str
    run_id: int | None = None
    progress: int | None = None
    exec_state: str = ""
    health_state: str = ""
    result: str = ""
    current_profile: int | None = None
    active_profile: int | None = None
    best_profile: int | None = None
    current_score: int | None = None
    best_score: int | None = None
    elapsed_ms: int | None = None
    note: str = ""


class ValidationLogger:
    FIELDS = tuple(RunRecord.__dataclass_fields__.keys())

    def __init__(self, output_dir: Path) -> None:
        output_dir.mkdir(parents=True, exist_ok=True)
        stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        self.csv_path = output_dir / f"autotune_validation_{stamp}.csv"
        self.jsonl_path = output_dir / f"autotune_validation_{stamp}.jsonl"
        self._csv_file = self.csv_path.open("w", newline="", encoding="utf-8-sig")
        self._jsonl_file = self.jsonl_path.open("w", encoding="utf-8")
        self._writer = csv.DictWriter(self._csv_file, fieldnames=self.FIELDS)
        self._writer.writeheader()

    def write(self, record: RunRecord) -> None:
        row = asdict(record)
        self._writer.writerow(row)
        self._jsonl_file.write(json.dumps(row, ensure_ascii=False) + "\n")
        self._csv_file.flush()
        self._jsonl_file.flush()

    def close(self) -> None:
        self._csv_file.close()
        self._jsonl_file.close()


def timestamp_now() -> str:
    return datetime.now().isoformat(timespec="milliseconds")
