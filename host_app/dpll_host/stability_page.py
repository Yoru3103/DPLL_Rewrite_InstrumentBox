"""Qt adapter for the nonblocking fixed-PID test sequence."""
import json
from pathlib import Path
from uuid import uuid4

from PyQt6.QtCore import QTimer, pyqtSignal
from PyQt6.QtWidgets import (QWidget, QVBoxLayout, QFormLayout, QLabel, QLineEdit,
                             QSpinBox, QPlainTextEdit, QPushButton, QMessageBox)

from .stability import (DEFAULT_PROFILES, Settings, StabilityRun, Canceled,
                        parse_profiles, rank_results)


class StabilityPage(QWidget):
    request = pyqtSignal(str, int, bytes)
    start_requested = pyqtSignal()
    running_changed = pyqtSignal(bool)

    def __init__(self):
        super().__init__()
        self.active = False
        self.pending = None
        self.run = None
        self.cancel = False
        layout = QVBoxLayout(self)
        hint = QLabel("仅测频回路：预先设置中心频率并锁定。固定 PID → 稳定等待 → 1 秒门宽连续测频。\n"
                      "比较标准差/峰峰值，不运行 PS Autotune；完成后恢复原 PID 与门宽，不自动应用推荐组。\n"
                      "PID 切换仍为 legacy 写入，有暂态。仅使用已确认安全的参数，D_COEF 保持原值。")
        hint.setWordWrap(True)
        layout.addWidget(hint)
        self.profiles = QPlainTextEdit(json.dumps(DEFAULT_PROFILES, ensure_ascii=False, indent=2))
        layout.addWidget(self.profiles)
        form = QFormLayout()
        self.settle = QSpinBox(); self.settle.setRange(0, 300); self.settle.setValue(3)
        self.samples = QSpinBox(); self.samples.setRange(2, 3600); self.samples.setValue(30)
        self.repeats = QSpinBox(); self.repeats.setRange(1, 20); self.repeats.setValue(3)
        self.nominal = QLineEdit("40000000")
        self.output = QLineEdit(str(Path.cwd() / "validation_logs"))
        form.addRow("稳定等待（秒）", self.settle)
        form.addRow("每组每轮样本数（每点门宽 1 秒）", self.samples)
        form.addRow("重复轮数（每轮依次测所有组）", self.repeats)
        form.addRow("标称频率（Hz，仅用于偏差统计）", self.nominal)
        form.addRow("日志目录", self.output)
        layout.addLayout(form)
        self.start_button = QPushButton("开始固定 PID 比较")
        self.stop_button = QPushButton("停止并恢复原参数")
        self.stop_button.setEnabled(False)
        layout.addWidget(self.start_button); layout.addWidget(self.stop_button)
        self.status = QLabel("等待开始；默认计划约需 9 分钟，串口开销会延长时间")
        self.status.setWordWrap(True)
        layout.addWidget(self.status)
        self.results = QPlainTextEdit()
        self.results.setReadOnly(True)
        self.results.setMaximumBlockCount(1000)
        layout.addWidget(self.results)
        self.timer = QTimer(self)
        self.timer.setSingleShot(True)
        self.timer.timeout.connect(self._drive)
        self.start_button.clicked.connect(self.start_requested.emit)
        self.stop_button.clicked.connect(self.stop)

    def start(self):
        if self.active:
            return
        try:
            profiles = parse_profiles(self.profiles.toPlainText())
            settings = Settings(self.settle.value(), self.samples.value(), self.repeats.value(), float(self.nominal.text()))
            settings.validate()
        except (ValueError, KeyError, TypeError) as exc:
            QMessageBox.warning(self, "测试计划错误", str(exc)); return
        if QMessageBox.question(self, "确认安全参数", "确认输入稳定、测频已开启，所有候选 PID 已验证安全？\n"
                                "本测试会切换 PID，产生暂态；退出时尝试恢复原参数。") != QMessageBox.StandardButton.Yes:
            return
        try:
            self.run = StabilityRun(profiles, settings, self.output.text())
        except OSError as exc:
            QMessageBox.warning(self, "日志创建失败", str(exc)); return
        self.sequence = self.run.sequence()
        self.token = uuid4().hex
        self.counter = 0
        self.shown = 0
        self.active = True
        self.pending = None
        self.cancel = False
        self.results.clear()
        self.results.appendPlainText(f"原始日志：{self.run.raw_path}\n汇总：{self.run.summary_path}\n事件：{self.run.event_path}")
        self._controls(True)
        self.running_changed.emit(True)
        self._drive()

    def _controls(self, running):
        for widget in (self.profiles, self.settle, self.samples, self.repeats, self.nominal, self.output, self.start_button):
            widget.setEnabled(not running)
        self.stop_button.setEnabled(running)

    def _drive(self, payload=None, error=None):
        if not self.active:
            return
        try:
            if self.cancel and not self.run.restoring:
                self.cancel = False
                command, data, delay = self.sequence.throw(Canceled("用户停止"))
            elif error is not None:
                command, data, delay = self.sequence.throw(error)
            else:
                command, data, delay = self.sequence.send(payload)
            self._show_rows()
            if self.run.restoring:
                self.status.setText("正在恢复原 PID 和门宽，请勿断开串口…")
                self.stop_button.setEnabled(False)
            else:
                self.status.setText(f"{self.run.progress}；已完成 {len(self.run.rows)} 组/轮")
            if command is None:
                self.timer.start(max(1, int(delay * 1000)))
            else:
                self.counter += 1
                self.pending = f"stability:{self.token}:{self.counter}"
                self.request.emit(self.pending, int(command), data)
        except StopIteration:
            self._finish("完成", True)
        except Exception as exc:
            self._finish(str(exc), False)

    def response(self, tag, payload):
        if self.active and tag == self.pending:
            self.pending = None
            self._drive(payload)

    def failed(self, tag, message):
        if self.active and tag == self.pending:
            self.pending = None
            self._drive(error=RuntimeError(message))

    def stop(self):
        if not self.active or self.run.restoring:
            return
        self.cancel = True
        self.timer.stop()
        self.status.setText("停止请求已接受，等待在途命令结束后恢复…")
        if self.pending is None:
            self._drive()

    def disconnected(self):
        if self.active:
            self._finish("串口断开，无法确认参数恢复，请按事件日志中的 ORIGINAL 人工恢复", False)

    def _show_rows(self):
        for r in self.run.rows[self.shown:]:
            self.results.appendPlainText(f"{r['name']} 第{r['repetition']}轮：N={r['n']}，"
                                         f"均值={r['mean_hz']:.6f} Hz，标准差={r['std_hz']:.6f} Hz，"
                                         f"峰峰值={r['p2p_hz']:.6f} Hz，偏差={r['offset_hz']:.6f} Hz")
        self.shown = len(self.run.rows)

    def _finish(self, message, complete):
        self.timer.stop()
        self._show_rows()
        ranked = rank_results(self.run.rows, self.run.settings.repeats) if complete else []
        if ranked:
            self.results.appendPlainText("参考排序（标准差越小越好，非自动选参）：")
            for index, r in enumerate(ranked, 1):
                self.results.appendPlainText(f"{index}. {r['name']}：标准差 RMS={r['std_hz']:.6f} Hz，最大峰峰值={r['p2p_hz']:.6f} Hz")
            self.results.appendPlainText("近似并列或全零时不能判定显著改善；请结合各轮重复性与测量分辨率。")
        restore = "原 PID/门宽已恢复并读回（请确认重新锁定）" if self.run.restored else (
            "尚未写配置" if not self.run.changed else "恢复未确认，请人工恢复原 PID/门宽")
        self.status.setText(f"{message}；{restore}")
        self.run.event("FINISH", message=message, complete=complete, restored=self.run.restored, ranking=ranked)
        self.run.close()
        self.sequence.close()
        self.active = False
        self.pending = None
        self._controls(False)
        self.running_changed.emit(False)
