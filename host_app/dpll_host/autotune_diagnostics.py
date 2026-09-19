"""Version 2 Autotune wire contract; no Qt or device dependencies."""
from __future__ import annotations

from dataclasses import asdict, dataclass
from datetime import datetime
import json
import math
from pathlib import Path
import struct

from .protocol import ProtocolError

DIAGNOSTIC_PAGES = 9
MODE_NAMES = {0: 'BASELINE', 1: 'CANDIDATE', 2: 'CONTROL', 3: 'VERIFY',
              4: 'RESTORE', 5: 'CALIBRATE'}
REASON_NAMES = ('DATA', 'COVERAGE', 'SIGNAL', 'LOCK', 'RAIL', 'RESIDUAL',
                'PHASE_SAT', 'OUTPUT', 'EVENTS', 'DRIFT', 'VERIFY', 'IO',
                'TIMEOUT', 'UNSUPPORTED', 'CANCEL')
PAGE_FIELDS = (
    ('reasons', 'windows', 'missing', 'pairs', 'flips', 'read_errors', 'elapsed_ms', 'samples_low'),
    ('samples_high', 'first_seq', 'last_seq', 'loss_events', 'positive_rail_events',
     'negative_rail_events', 'commit_errors', 'amplitude_min'),
    ('frequency_mean', 'frequency_rms', 'frequency_std', 'frequency_mae', 'frequency_peak',
     'phase_mean', 'phase_mae', 'phase_peak'),
    ('mean_abs_slope', 'slope_fraction', 'flip_rate', 'window_abs_frequency_mean',
     'amplitude_mean', 'coverage', 'lock_fraction', 'residual_fraction'),
    ('rail_fraction', 'phase_saturation_fraction', 'output_headroom', 'score',
     'frequency_bad_fraction', 'phase_bad_fraction', 'scale_f', 'scale_p'),
    ('amplitude_max', 'output_min', 'output_max', 'kp', 'ki', 'kii', 'kd', 'd_coefficient'),
    ('scale_d', 'deadband', 'group_mean', 'group_spread', 'baseline_mean',
     'baseline_spread', 'best_mean', 'best_spread'),
    ('window_ms', 'repeats', 'coverage_permille', 'amplitude_floor', 'improvement_permille',
     'clock_hz', 'window_samples', 'settle_ms'),
    ('phase_offset', 'output_low', 'output_high', 'group_size', 'best_profile',
     'reserved_8_5', 'reserved_8_6', 'reserved_8_7'),
)


@dataclass(frozen=True)
class AutotuneConfig:
    window_ms: int = 1000
    repeats: int = 3
    coverage_permille: int = 800
    amplitude_floor: int = 16
    improvement_permille: int = 30

    def validate(self) -> None:
        if not 1000 <= self.window_ms <= 2000:
            raise ValueError('每轮窗口必须为 1000～2000 ms')
        if not 2 <= self.repeats <= 5 or self.window_ms * self.repeats > 6000:
            raise ValueError('重复次数须为 2～5，窗口 × 重复次数不可超过 6000 ms')
        if not 800 <= self.coverage_permille <= 1000:
            raise ValueError('最小覆盖率必须为 800～1000 ‰')
        if not 1 <= self.amplitude_floor <= 65535:
            raise ValueError('幅值底限必须为 1～65535 raw')
        if not 1 <= self.improvement_permille <= 500:
            raise ValueError('最小改善必须为 1～500 ‰')

    def pack(self) -> bytes:
        self.validate()
        return b'\x07' + struct.pack('<5I', *asdict(self).values())


def unpack_config(payload: bytes) -> AutotuneConfig:
    if len(payload) != 24 or payload[:4] != b'\x02\x06\x00\x00':
        raise ProtocolError('无效的 Autotune v2 配置响应')
    config = AutotuneConfig(*struct.unpack_from('<5I', payload, 4))
    try:
        config.validate()
    except ValueError as exc:
        raise ProtocolError(str(exc)) from exc
    return config


def diagnostic_request(page: int) -> bytes:
    if not 0 <= page < DIAGNOSTIC_PAGES:
        raise ValueError('diagnostic page out of range')
    return bytes((5, page))


class DiagnosticBatch:
    """Assemble only ordered pages with exactly one frozen report header."""

    def __init__(self) -> None:
        self.pages: list[bytes] = []
        self.identity: tuple[int, ...] | None = None

    def add(self, payload: bytes) -> dict | None:
        expected = len(self.pages)
        if len(payload) != 44 or payload[:2] != b'\x02\x05':
            raise ProtocolError('诊断页必须为 44 字节的 v2/action5 响应')
        if expected >= DIAGNOSTIC_PAGES or payload[2] != expected:
            raise ProtocolError('诊断页顺序不一致；丢弃整批')
        identity = (payload[3], struct.unpack_from('<I', payload, 4)[0], *payload[8:12])
        if self.identity is not None and identity != self.identity:
            raise ProtocolError('诊断报告标识或头字段变化；丢弃整批')
        self.identity = identity
        # Reject non-finite floats before storing a batch or writing JSON.
        if expected in (2, 3, 4, 6) and not all(math.isfinite(v) for v in struct.unpack_from('<8f', payload, 12)):
            raise ProtocolError('诊断报告包含非有限浮点数')
        self.pages.append(payload)
        return self.report() if len(self.pages) == DIAGNOSTIC_PAGES else None

    def report(self) -> dict:
        if len(self.pages) != DIAGNOSTIC_PAGES or self.identity is None:
            raise ProtocolError('诊断页未收齐')
        run_id, report_id, mode, profile, repeat, valid = self.identity
        fields = {}
        for index, payload in enumerate(self.pages):
            fmt = '<8f' if index in (2, 3, 4, 6) else '<8I'
            fields.update(zip(PAGE_FIELDS[index], struct.unpack_from(fmt, payload, 12)))
        for name in ('output_min', 'output_max', 'phase_offset', 'output_low', 'output_high'):
            if fields[name] & 0x80000000:
                fields[name] -= 1 << 32
        fields['samples'] = (fields.pop('samples_high') << 32) | fields.pop('samples_low')
        fields['reason_names'] = [name for bit, name in enumerate(REASON_NAMES) if fields['reasons'] & (1 << bit)]
        return {'protocol_version': 2, 'run_id': run_id, 'report_id': report_id,
                'mode': MODE_NAMES.get(mode, f'UNKNOWN({mode})'), 'mode_id': mode,
                'profile': profile, 'repeat_index': repeat, 'valid_bits': valid,
                'qualified': bool(valid & 1), 'flip_available': bool(valid & 2),
                'slope_available': bool(valid & 4), 'metrics': fields,
                'units': {'frequency': 'raw', 'phase': 'raw', 'mean_abs_slope': 'raw/s',
                          'amplitude': 'raw', 'output': 'raw', 'fractions': '0..1'},
                'raw_pages_hex': [p.hex() for p in self.pages]}


class DiagnosticLogger:
    """Append full reports only; a new serial connection starts a new file."""
    def __init__(self, directory: Path) -> None:
        directory.mkdir(parents=True, exist_ok=True)
        self.path = directory / ('autotune_metrics_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f') + '.jsonl')
        self.file = self.path.open('x', encoding='utf-8')
        self.seen: set[tuple[str, int, int]] = set()

    def write(self, target: str, report: dict) -> bool:
        key = (target, report['run_id'], report['report_id'])
        if not report['report_id'] or key in self.seen:
            return False
        row = {'timestamp': datetime.now().isoformat(timespec='milliseconds'), 'target': target, **report}
        self.file.write(json.dumps(row, ensure_ascii=False, allow_nan=False) + '\n')
        self.file.flush()
        self.seen.add(key)
        return True

    def close(self) -> None:
        self.file.close()
