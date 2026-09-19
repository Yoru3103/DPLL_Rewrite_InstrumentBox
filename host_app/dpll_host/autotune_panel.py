"""Non-blocking v2 configuration and frozen diagnostic report UI."""
from __future__ import annotations

import json
from pathlib import Path

from PyQt6.QtCore import QObject, QTimer, pyqtSignal
from PyQt6.QtWidgets import (QFormLayout, QHBoxLayout, QLabel, QPlainTextEdit,
                            QPushButton, QSpinBox, QVBoxLayout, QWidget)

from .protocol import AutotuneStatus, LoopTarget, ProtocolError, unpack_autotune
from .autotune_diagnostics import (AutotuneConfig, DiagnosticBatch, DiagnosticLogger,
                                   diagnostic_request, unpack_config)


class AutotuneDetail(QWidget):
    read_requested = pyqtSignal()
    write_requested = pyqtSignal()

    def __init__(self) -> None:
        super().__init__()
        layout = QVBoxLayout(self)
        self.support = QLabel('连接后先 QUERY；扩展功能需要协议 v2')
        layout.addWidget(self.support)
        form = QFormLayout()
        self.fields: dict[str, QSpinBox] = {}
        definitions = (
            ('window_ms', '每轮采集窗口（ms）', 1000, 2000, 1000),
            ('repeats', '重复次数（窗口 × 次数 ≤ 6000 ms）', 2, 5, 3),
            ('coverage_permille', '最小时间覆盖率（‰）', 800, 1000, 800),
            ('amplitude_floor', '幅值底限（raw）', 1, 65535, 16),
            ('improvement_permille', '最小相对改善（‰）', 1, 500, 30),
        )
        for key, text, lower, upper, default in definitions:
            spin = QSpinBox()
            spin.setRange(lower, upper)
            spin.setValue(default)
            self.fields[key] = spin
            form.addRow(text, spin)
        layout.addLayout(form)
        buttons = QHBoxLayout()
        self.read_button = QPushButton('读取配置')
        self.write_button = QPushButton('提交配置并读回')
        buttons.addWidget(self.read_button)
        buttons.addWidget(self.write_button)
        self.config_status = QLabel('配置尚未从设备读取；输入框为工程默认值')
        layout.addLayout(buttons)
        layout.addWidget(self.config_status)
        self.report = QPlainTextEdit()
        self.report.setReadOnly(True)
        self.report.setPlaceholderText('完整指标报告：频率/相位 raw，斜率 raw/s，比例 0～1。\n报告是低频轮询快照，采集结果由 PS 判定。')
        layout.addWidget(self.report, 1)
        self.read_button.clicked.connect(self.read_requested)
        self.write_button.clicked.connect(self.write_requested)
        self.set_available(False, False)

    def set_available(self, supported: bool, writable: bool) -> None:
        self.read_button.setEnabled(supported)
        self.write_button.setEnabled(writable)
        for field in self.fields.values():
            field.setEnabled(writable)

    def config(self) -> AutotuneConfig:
        config = AutotuneConfig(**{key: field.value() for key, field in self.fields.items()})
        config.validate()
        return config

    def show_config(self, config: AutotuneConfig, verified: bool) -> None:
        for key, field in self.fields.items():
            field.setValue(getattr(config, key))
        self.config_status.setText('提交成功，读回完全一致' if verified else '设备配置已读取')

    def show_report(self, report: dict) -> None:
        metrics = report['metrics']
        valid = ('合格' if report['qualified'] else '未合格')
        reasons = ', '.join(metrics['reason_names']) or '无'
        summary = (f"RUN {report['run_id']} / 报告 {report['report_id']} / {report['mode']} / "
                   f"候选 {report['profile']} / 第 {report['repeat_index'] + 1} 轮\n"
                   f"{valid}；原因：{reasons}\n"
                   f"频率 RMS {metrics['frequency_rms']:.6g} raw；"
                   f"相位 MAE {metrics['phase_mae']:.6g} raw；J {metrics['score']:.6g}\n"
                   f"覆盖率 {metrics['coverage']:.1%}；锁定比例 {metrics['lock_fraction']:.1%}\n"
                   f"翻转率 {'可用' if report['flip_available'] else '不可用'}；"
                   f"相位斜率 {'可用' if report['slope_available'] else '不可用'}\n\n")
        self.report.setPlainText(summary + json.dumps({k: v for k, v in report.items() if k != 'raw_pages_hex'}, ensure_ascii=False, indent=2))


class AutotuneDiagnostics(QObject):
    request = pyqtSignal(str, int, bytes)
    log = pyqtSignal(str)

    def __init__(self, panels: dict[LoopTarget, AutotuneDetail], output, parent=None) -> None:
        super().__init__(parent)
        self.panels = panels
        self.output = output
        self.connected = False
        self.suspended = False
        self.background = True
        self.epoch = 0
        self.versions: dict[LoopTarget, int] = {}
        self.busy: dict[LoopTarget, bool] = {}
        self.config_seen: set[LoopTarget] = set()
        self.config_pending: dict[LoopTarget, AutotuneConfig | None] = {}
        self.batch: DiagnosticBatch | None = None
        self.batch_target: LoopTarget | None = None
        self.seen: dict[LoopTarget, tuple[int, ...]] = {}
        self.next_target = 0
        self.logger: DiagnosticLogger | None = None
        for target, panel in panels.items():
            panel.read_requested.connect(lambda t=target: self.read_config(t))
            panel.write_requested.connect(lambda t=target: self.write_config(t))
        self.timer = QTimer(self)
        self.timer.setInterval(1000)
        self.timer.timeout.connect(self.tick)
        self.timer.start()

    def set_connected(self, connected: bool) -> None:
        self.connected = connected
        self.epoch += 1
        self.batch = None
        self.batch_target = None
        self.versions.clear()
        self.busy.clear()
        self.config_seen.clear()
        self.config_pending.clear()
        self.seen.clear()
        if self.logger:
            self.log.emit(f'Autotune 指标日志已保存：{self.logger.path}')
            self.logger.close()
            self.logger = None
        for panel in self.panels.values():
            panel.support.setText('连接后先 QUERY；扩展功能需要协议 v2')
            panel.config_status.setText('配置尚未从当前设备读取')
            panel.report.clear()
        self._availability()

    def set_suspended(self, suspended: bool) -> None:
        self.suspended = suspended
        self.epoch += 1
        self.batch = None
        self.batch_target = None
        self.config_pending.clear()
        self._availability()

    def _availability(self) -> None:
        for target, panel in self.panels.items():
            allowed = self.connected and not self.suspended and self.versions.get(target) == 2
            panel.set_available(allowed and target not in self.config_pending,
                                allowed and not any(self.busy.values()) and target not in self.config_pending)

    def status(self, target: LoopTarget, status: AutotuneStatus) -> None:
        self.versions[target] = status.protocol_version
        self.busy[target] = status.busy
        self.panels[target].support.setText('协议 v2：PS 自主整定，HOST_ONLY；指标 raw，斜率 raw/s' if status.protocol_version == 2
                                           else '协议 v1：仅支持旧状态/控制，扩展配置与诊断不可用')
        self._availability()

    def _emit(self, target: LoopTarget, operation: str, payload: bytes) -> None:
        self.request.emit(f'autotune:{target.name.lower()}:{operation}:{self.epoch}', target.command, payload)

    def tick(self) -> None:
        if not self.connected or self.suspended or not self.background or self.batch is not None:
            return
        targets = [target for target in LoopTarget if self.busy.get(target)]
        if not targets:
            targets = [LoopTarget((self.next_target + offset) % 2) for offset in range(2)]
        for target in targets:
            if self.versions.get(target) != 2 or target in self.config_pending:
                continue
            self.next_target = 1 - int(target)
            if target not in self.config_seen and not any(self.busy.values()):
                self.read_config(target)
                return
            self.batch = DiagnosticBatch()
            self.batch_target = target
            self._emit(target, 'diag_0', diagnostic_request(0))
            return

    def read_config(self, target: LoopTarget, expected: AutotuneConfig | None = None) -> None:
        if not self.connected or self.suspended or self.versions.get(target) != 2:
            return
        self.config_pending[target] = expected
        self._availability()
        self._emit(target, 'config_read', b'\x06')

    def write_config(self, target: LoopTarget) -> None:
        if not self.connected or self.suspended or self.versions.get(target) != 2 or any(self.busy.values()):
            return
        try:
            config = self.panels[target].config()
        except ValueError as exc:
            self.panels[target].config_status.setText(str(exc))
            return
        self.config_pending[target] = config
        self._availability()
        self._emit(target, 'config_write', config.pack())

    def response(self, tag: str, payload: bytes) -> bool:
        parts = tag.split(':')
        operation = parts[2]
        if not (operation.startswith('diag_') or operation.startswith('config_')):
            return False
        if len(parts) != 4 or parts[3] != str(self.epoch) or not self.connected or self.suspended:
            return True  # Late reply from a canceled batch/previous connection.
        target = LoopTarget.FREQ if parts[1] == 'freq' else LoopTarget.DPLL
        if operation == 'config_write':
            status = unpack_autotune(payload)
            if status.protocol_version != 2 or status.action != 7 or status.result_code != 1:
                raise ProtocolError('配置提交失败：' + status.result_name)
            self.read_config(target, self.config_pending.get(target))
        elif operation == 'config_read':
            config = unpack_config(payload)
            expected = self.config_pending.pop(target, None)
            if expected is not None and expected != config:
                raise ProtocolError('配置读回与提交值不一致')
            self.config_seen.add(target)
            self.panels[target].show_config(config, expected is not None)
            self._availability()
        else:
            if self.batch is None or target != self.batch_target:
                return True
            if int(operation[5:]) != len(self.batch.pages):
                raise ProtocolError('诊断请求页与批次不一致')
            report = self.batch.add(payload)
            if len(self.batch.pages) == 1 and (not self.batch.identity[1] or self.seen.get(target) == self.batch.identity):
                self.batch = None
                self.batch_target = None
                return True
            if report is None:
                page = len(self.batch.pages)
                self._emit(target, f'diag_{page}', diagnostic_request(page))
            else:
                identity = self.batch.identity
                self.batch = None
                self.batch_target = None
                self.panels[target].show_report(report)
                try:
                    if self.logger is None:
                        self.logger = DiagnosticLogger(Path(self.output.text()).expanduser())
                        self.log.emit(f'Autotune 指标日志：{self.logger.path}')
                    self.logger.write(target.name.lower(), report)
                except (OSError, ValueError) as exc:
                    self.log.emit(f'Autotune 指标日志保存失败：{exc}')
                    return True  # Retry this report; never claim that it was saved.
                self.seen[target] = identity
        return True

    def failed(self, tag: str, message: str) -> None:
        parts = tag.split(':')
        if len(parts) != 4 or parts[3] != str(self.epoch):
            return
        target = LoopTarget.FREQ if parts[1] == 'freq' else LoopTarget.DPLL
        if parts[2].startswith('diag_'):
            self.batch = None
            self.batch_target = None
            self.panels[target].support.setText('本次诊断未收齐，已丢弃：' + message)
        elif parts[2].startswith('config_'):
            self.config_pending.pop(target, None)
            self.panels[target].config_status.setText('配置操作失败：' + message)
        self._availability()
