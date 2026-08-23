from __future__ import annotations

from collections import deque
from pathlib import Path
import json
import sys
import time

from PyQt6.QtCore import QAbstractTableModel, QModelIndex, QObject, Qt, QTimer, pyqtSignal
from PyQt6.QtGui import QColor, QFont
from PyQt6.QtWidgets import (
    QApplication, QCheckBox, QComboBox, QFileDialog, QFormLayout, QGridLayout,
    QGroupBox, QHBoxLayout, QHeaderView, QLabel, QLineEdit, QMainWindow,
    QMessageBox, QPlainTextEdit, QProgressBar, QPushButton, QSpinBox,
    QTabWidget, QTableView, QVBoxLayout, QWidget,
)
from serial.tools import list_ports

from .protocol import (
    AutotuneAction, AutotunePolicy, AutotuneStatus, Command, LoopTarget,
    ProtocolError, pack_autotune, pack_pid, pack_u32, profile_name, unpack_ack,
    unpack_autotune, unpack_pid, unpack_u32,
)
from .transport import SerialWorker
from .validation import (
    RunRecord, ValidationCase, ValidationLogger, default_plan_text, parse_int,
    parse_plan, timestamp_now,
)


def parse_u32(text: str) -> int:
    return parse_int(text.strip())


def target_name(target: LoopTarget) -> str:
    return "测频回路" if target is LoopTarget.FREQ else "锁相回路"


class ConnectionBar(QWidget):
    connect_requested = pyqtSignal(str, int)
    disconnect_requested = pyqtSignal()

    def __init__(self) -> None:
        super().__init__()
        layout = QHBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(8)
        self.port = QComboBox()
        self.port.setMinimumWidth(180)
        self.baud = QComboBox()
        self.baud.addItems(["921600", "460800", "115200"])
        refresh = QPushButton("刷新串口")
        self.connect_button = QPushButton("连接")
        self.status = QLabel("● 未连接")
        self.status.setObjectName("connectionStatus")
        self.firmware = QLabel("固件版本：—")
        layout.addWidget(QLabel("串口"))
        layout.addWidget(self.port)
        layout.addWidget(QLabel("波特率"))
        layout.addWidget(self.baud)
        layout.addWidget(refresh)
        layout.addWidget(self.connect_button)
        layout.addStretch()
        layout.addWidget(self.firmware)
        layout.addWidget(self.status)
        refresh.clicked.connect(self.refresh)
        self.connect_button.clicked.connect(self._toggle)
        self.refresh()

    def refresh(self) -> None:
        current = self.port.currentText()
        self.port.clear()
        ports = [item.device for item in list_ports.comports()]
        self.port.addItems(ports)
        if current in ports:
            self.port.setCurrentText(current)

    def _toggle(self) -> None:
        if self.connect_button.text() == "连接":
            if not self.port.currentText():
                QMessageBox.warning(self, "串口", "未发现可用串口")
                return
            self.connect_requested.emit(self.port.currentText(), int(self.baud.currentText()))
        else:
            self.disconnect_requested.emit()

    def set_connected(self, connected: bool, message: str) -> None:
        self.connect_button.setText("断开" if connected else "连接")
        self.port.setEnabled(not connected)
        self.baud.setEnabled(not connected)
        self.status.setText(("● 已连接：" if connected else "● ") + message)
        self.status.setProperty("connected", connected)
        self.status.style().unpolish(self.status)
        self.status.style().polish(self.status)


class LoopManualCard(QGroupBox):
    request = pyqtSignal(str, int, bytes)

    def __init__(self, target: LoopTarget) -> None:
        super().__init__(target_name(target))
        self.target = target
        layout = QVBoxLayout(self)
        form = QFormLayout()
        self.center = QLineEdit("0")
        self.center.setPlaceholderText("十进制或 0x 十六进制寄存器值")
        center_buttons = QHBoxLayout()
        read_center = QPushButton("读取中心频率")
        write_center = QPushButton("写入中心频率")
        center_buttons.addWidget(read_center)
        center_buttons.addWidget(write_center)
        center_row = QWidget()
        center_row_layout = QVBoxLayout(center_row)
        center_row_layout.setContentsMargins(0, 0, 0, 0)
        center_row_layout.addWidget(self.center)
        center_row_layout.addLayout(center_buttons)
        form.addRow("中心频率寄存器", center_row)

        self.pid_fields: dict[str, QLineEdit] = {}
        for name in ("Kp", "Ki", "Kii", "Kd"):
            field = QLineEdit("0")
            field.setPlaceholderText("uint32，支持 0x 前缀")
            self.pid_fields[name] = field
            form.addRow(name, field)
        layout.addLayout(form)

        pid_buttons = QHBoxLayout()
        read_pid = QPushButton("读取 PID")
        write_pid = QPushButton("写入完整 PID")
        pid_buttons.addWidget(read_pid)
        pid_buttons.addWidget(write_pid)
        layout.addLayout(pid_buttons)

        control_buttons = QHBoxLayout()
        if target is LoopTarget.DPLL:
            loop_on = QPushButton("锁相开启")
            loop_off = QPushButton("锁相关闭")
            control_buttons.addWidget(loop_on)
            control_buttons.addWidget(loop_off)
            loop_on.clicked.connect(lambda: self.request.emit("manual:dpll:on", Command.DPLL_ON, b""))
            loop_off.clicked.connect(lambda: self.request.emit("manual:dpll:off", Command.DPLL_OFF, b""))
        else:
            reset = QPushButton("测频环路复位")
            control_buttons.addWidget(reset)
            reset.clicked.connect(lambda: self.request.emit("manual:freq:reset", Command.FREQ_RESET, b""))
        control_buttons.addStretch()
        layout.addLayout(control_buttons)

        read_center.clicked.connect(self._read_center)
        write_center.clicked.connect(self._write_center)
        read_pid.clicked.connect(self._read_pid)
        write_pid.clicked.connect(self._write_pid)

    def _commands(self) -> tuple[Command, Command, Command, Command]:
        if self.target is LoopTarget.FREQ:
            return Command.READ_FREQ_CENTER, Command.WRITE_FREQ_CENTER, Command.READ_FREQ_PID, Command.WRITE_FREQ_PID
        return Command.READ_DPLL_CENTER, Command.WRITE_DPLL_CENTER, Command.READ_DPLL_PID, Command.WRITE_DPLL_PID

    def _read_center(self) -> None:
        read_center, _, _, _ = self._commands()
        self.request.emit(f"manual:{self.target.name.lower()}:read_center", read_center, b"")

    def _write_center(self) -> None:
        try:
            payload = pack_u32(parse_u32(self.center.text()))
        except ValueError as exc:
            QMessageBox.warning(self, "输入错误", str(exc))
            return
        _, write_center, _, _ = self._commands()
        self.request.emit(f"manual:{self.target.name.lower()}:write_center", write_center, payload)

    def _read_pid(self) -> None:
        _, _, read_pid, _ = self._commands()
        self.request.emit(f"manual:{self.target.name.lower()}:read_pid", read_pid, b"")

    def _write_pid(self) -> None:
        try:
            values = [parse_u32(self.pid_fields[name].text()) for name in ("Kp", "Ki", "Kii", "Kd")]
            payload = pack_pid(*values)
        except ValueError as exc:
            QMessageBox.warning(self, "输入错误", str(exc))
            return
        _, _, _, write_pid = self._commands()
        self.request.emit(f"manual:{self.target.name.lower()}:write_pid", write_pid, payload)

    def handle_response(self, operation: str, payload: bytes) -> None:
        if operation == "read_center":
            value = unpack_u32(payload)
            self.center.setText(f"0x{value:08X}")
        elif operation == "read_pid":
            values = unpack_pid(payload)
            for name, value in zip(("Kp", "Ki", "Kii", "Kd"), values):
                self.pid_fields[name].setText(str(value))
        else:
            unpack_ack(payload)


class ManualPage(QWidget):
    request = pyqtSignal(str, int, bytes)

    def __init__(self) -> None:
        super().__init__()
        layout = QGridLayout(self)
        layout.setSpacing(16)
        self.freq = LoopManualCard(LoopTarget.FREQ)
        self.dpll = LoopManualCard(LoopTarget.DPLL)
        self.freq.request.connect(self.request)
        self.dpll.request.connect(self.request)
        layout.addWidget(self.freq, 0, 0)
        layout.addWidget(self.dpll, 0, 1)
        layout.setColumnStretch(0, 1)
        layout.setColumnStretch(1, 1)

    def handle_response(self, tag: str, payload: bytes) -> None:
        _, target, operation = tag.split(":", 2)
        (self.freq if target == "freq" else self.dpll).handle_response(operation, payload)


class AutotuneCard(QGroupBox):
    action_requested = pyqtSignal(int, int, int)

    def __init__(self, target: LoopTarget) -> None:
        super().__init__(target_name(target))
        self.target = target
        layout = QVBoxLayout(self)
        top = QHBoxLayout()
        self.policy = QComboBox()
        self.policy.addItems(["HOST_ONLY", "BOOT_ONCE", "BOOT_AND_RECOVER"])
        set_policy = QPushButton("设置策略")
        top.addWidget(QLabel("触发策略"))
        top.addWidget(self.policy)
        top.addWidget(set_policy)
        layout.addLayout(top)

        buttons = QHBoxLayout()
        for text, action in (("START", AutotuneAction.START), ("QUERY", AutotuneAction.QUERY),
                             ("CANCEL", AutotuneAction.CANCEL), ("CLEAR", AutotuneAction.CLEAR)):
            button = QPushButton(text)
            buttons.addWidget(button)
            button.clicked.connect(lambda _checked=False, a=action: self._emit(a))
        layout.addLayout(buttons)

        self.progress = QProgressBar()
        self.progress.setRange(0, 100)
        layout.addWidget(self.progress)
        grid = QGridLayout()
        self.labels: dict[str, QLabel] = {}
        fields = ("事务状态", "健康状态", "结果", "RUN_ID", "当前候选", "活动档位", "最佳档位",
                  "当前分数", "最佳分数", "耗时", "ADAPT_READY")
        for index, field in enumerate(fields):
            label = QLabel("—")
            self.labels[field] = label
            grid.addWidget(QLabel(field), index // 2, (index % 2) * 2)
            grid.addWidget(label, index // 2, (index % 2) * 2 + 1)
        layout.addLayout(grid)
        set_policy.clicked.connect(lambda: self._emit(AutotuneAction.SET_POLICY))

    def _emit(self, action: AutotuneAction) -> None:
        self.action_requested.emit(int(self.target), int(action), self.policy.currentIndex())

    def update_status(self, status: AutotuneStatus) -> None:
        self.progress.setValue(status.progress)
        values = {
            "事务状态": status.exec_name,
            "健康状态": status.health_name,
            "结果": status.result_name,
            "RUN_ID": str(status.run_id),
            "当前候选": f"{status.current_profile} / {profile_name(status.current_profile)}",
            "活动档位": f"{status.active_profile} / {profile_name(status.active_profile)}",
            "最佳档位": f"{status.best_profile} / {profile_name(status.best_profile)}",
            "当前分数": str(status.current_score),
            "最佳分数": str(status.best_score),
            "耗时": f"{status.elapsed_ms} ms",
            "ADAPT_READY": "是" if status.adapt_ready else "否",
        }
        for name, value in values.items():
            self.labels[name].setText(value)
        self.labels["ADAPT_READY"].setProperty("ready", status.adapt_ready)
        self.labels["ADAPT_READY"].style().unpolish(self.labels["ADAPT_READY"])
        self.labels["ADAPT_READY"].style().polish(self.labels["ADAPT_READY"])


class AutotunePage(QWidget):
    request = pyqtSignal(str, int, bytes)

    def __init__(self) -> None:
        super().__init__()
        layout = QVBoxLayout(self)
        controls = QHBoxLayout()
        self.auto_poll = QCheckBox("自动查询（250 ms）")
        self.auto_poll.setChecked(True)
        controls.addWidget(self.auto_poll)
        controls.addStretch()
        layout.addLayout(controls)
        cards = QGridLayout()
        self.freq = AutotuneCard(LoopTarget.FREQ)
        self.dpll = AutotuneCard(LoopTarget.DPLL)
        cards.addWidget(self.freq, 0, 0)
        cards.addWidget(self.dpll, 0, 1)
        layout.addLayout(cards)
        self.freq.action_requested.connect(self._action)
        self.dpll.action_requested.connect(self._action)
        self.poll_timer = QTimer(self)
        self.poll_timer.setInterval(250)
        self.poll_timer.timeout.connect(self._poll)
        self.poll_timer.start()

    def _action(self, target_value: int, action_value: int, policy_value: int) -> None:
        target = LoopTarget(target_value)
        action = AutotuneAction(action_value)
        policy = AutotunePolicy(policy_value) if action is AutotuneAction.SET_POLICY else None
        self.request.emit(
            f"autotune:{target.name.lower()}:{action.name.lower()}",
            target.command,
            pack_autotune(action, policy),
        )

    def _poll(self) -> None:
        if not self.auto_poll.isChecked():
            return
        for target in (LoopTarget.FREQ, LoopTarget.DPLL):
            self.request.emit(
                f"autotune:{target.name.lower()}:poll",
                target.command,
                pack_autotune(AutotuneAction.QUERY),
            )

    def handle_response(self, tag: str, payload: bytes) -> AutotuneStatus:
        status = unpack_autotune(payload)
        target = tag.split(":")[1]
        (self.freq if target == "freq" else self.dpll).update_status(status)
        return status


class RecordTableModel(QAbstractTableModel):
    HEADERS = ("时间", "案例", "回路", "次数", "事件", "RUN_ID", "进度", "状态", "结果", "最佳档", "最佳分数")

    def __init__(self) -> None:
        super().__init__()
        self.rows: list[RunRecord] = []

    def rowCount(self, parent=QModelIndex()) -> int:
        return len(self.rows)

    def columnCount(self, parent=QModelIndex()) -> int:
        return len(self.HEADERS)

    def headerData(self, section: int, orientation: Qt.Orientation, role=Qt.ItemDataRole.DisplayRole):
        if role == Qt.ItemDataRole.DisplayRole and orientation == Qt.Orientation.Horizontal:
            return self.HEADERS[section]
        return None

    def data(self, index: QModelIndex, role=Qt.ItemDataRole.DisplayRole):
        if not index.isValid():
            return None
        record = self.rows[index.row()]
        values = (record.timestamp, record.case_name, record.target, record.repetition, record.event,
                  record.run_id, record.progress, record.exec_state, record.result,
                  record.best_profile, record.best_score)
        if role == Qt.ItemDataRole.DisplayRole:
            value = values[index.column()]
            return "" if value is None else str(value)
        if role == Qt.ItemDataRole.ForegroundRole and record.event in {"FAILED", "ERROR"}:
            return QColor("#d94c4c")
        return None

    def append(self, record: RunRecord) -> None:
        row = len(self.rows)
        self.beginInsertRows(QModelIndex(), row, row)
        self.rows.append(record)
        self.endInsertRows()


class ValidationPage(QWidget):
    start_requested = pyqtSignal(str, str)
    stop_requested = pyqtSignal()

    def __init__(self) -> None:
        super().__init__()
        layout = QVBoxLayout(self)
        hint = QLabel("JSON 计划可为每个案例设置中心频率、PID、重复次数和是否运行 autotune；空值表示保持设备当前配置。")
        hint.setWordWrap(True)
        layout.addWidget(hint)
        self.plan = QPlainTextEdit(default_plan_text())
        self.plan.setFont(QFont("Consolas", 10))
        self.plan.setMinimumHeight(230)
        layout.addWidget(self.plan)
        path_row = QHBoxLayout()
        self.output_dir = QLineEdit(str(Path.cwd() / "validation_logs"))
        browse = QPushButton("选择日志目录")
        path_row.addWidget(QLabel("日志目录"))
        path_row.addWidget(self.output_dir)
        path_row.addWidget(browse)
        layout.addLayout(path_row)
        buttons = QHBoxLayout()
        self.start_button = QPushButton("开始完整验证")
        self.stop_button = QPushButton("停止并安全取消")
        self.stop_button.setEnabled(False)
        buttons.addWidget(self.start_button)
        buttons.addWidget(self.stop_button)
        buttons.addStretch()
        layout.addLayout(buttons)
        self.model = RecordTableModel()
        table = QTableView()
        table.setModel(self.model)
        table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeMode.ResizeToContents)
        table.horizontalHeader().setStretchLastSection(True)
        layout.addWidget(table)
        browse.clicked.connect(self._browse)
        self.start_button.clicked.connect(lambda: self.start_requested.emit(self.plan.toPlainText(), self.output_dir.text()))
        self.stop_button.clicked.connect(self.stop_requested)

    def _browse(self) -> None:
        selected = QFileDialog.getExistingDirectory(self, "选择验证日志目录", self.output_dir.text())
        if selected:
            self.output_dir.setText(selected)

    def set_running(self, running: bool) -> None:
        self.start_button.setEnabled(not running)
        self.stop_button.setEnabled(running)
        self.plan.setReadOnly(running)


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()
        self.setWindowTitle("DPLL 自适应调参与验证上位机")
        self.resize(1180, 820)
        self.worker: SerialWorker | None = None
        self.pending: set[str] = set()
        self.validation_queue: deque[tuple[ValidationCase, int]] = deque()
        self.validation_case: ValidationCase | None = None
        self.validation_repeat = 0
        self.validation_phase = "idle"
        self.validation_deadline = 0.0
        self.validation_logger: ValidationLogger | None = None

        root = QWidget()
        root_layout = QVBoxLayout(root)
        root_layout.setContentsMargins(16, 16, 16, 16)
        root_layout.setSpacing(16)
        title = QLabel("DPLL Instrument Box · 自适应调参与验证")
        title.setObjectName("pageTitle")
        root_layout.addWidget(title)
        self.connection = ConnectionBar()
        root_layout.addWidget(self.connection)
        self.tabs = QTabWidget()
        self.manual = ManualPage()
        self.autotune = AutotunePage()
        self.validation = ValidationPage()
        self.log = QPlainTextEdit()
        self.log.setReadOnly(True)
        self.log.setMaximumBlockCount(5000)
        self.tabs.addTab(self.manual, "手动控制")
        self.tabs.addTab(self.autotune, "Autotune")
        self.tabs.addTab(self.validation, "批次验证")
        self.tabs.addTab(self.log, "通信日志")
        root_layout.addWidget(self.tabs, 1)
        self.setCentralWidget(root)

        self.connection.connect_requested.connect(self.connect_serial)
        self.connection.disconnect_requested.connect(self.disconnect_serial)
        self.manual.request.connect(self.send_request)
        self.autotune.request.connect(self.send_request)
        self.validation.start_requested.connect(self.start_validation)
        self.validation.stop_requested.connect(self.stop_validation)
        self.validation_timer = QTimer(self)
        self.validation_timer.setInterval(250)
        self.validation_timer.timeout.connect(self._validation_tick)
        self._apply_style()

    def _apply_style(self) -> None:
        self.setStyleSheet("""
            QMainWindow, QWidget { background: #f4f6f8; color: #1f2933; font-size: 13px; }
            #pageTitle { font-size: 22px; font-weight: 700; color: #102a43; }
            QGroupBox { background: white; border: 1px solid #d9e2ec; border-radius: 8px;
                        margin-top: 14px; padding: 14px; font-weight: 600; }
            QGroupBox::title { subcontrol-origin: margin; left: 12px; padding: 0 6px; }
            QPushButton { background: #2368a2; color: white; border: 0; border-radius: 5px; padding: 7px 12px; }
            QPushButton:hover { background: #1b4f72; }
            QPushButton:disabled { background: #9fb3c8; }
            QLineEdit, QComboBox, QPlainTextEdit, QTableView { background: white; border: 1px solid #bcccdc;
                                                               border-radius: 4px; padding: 5px; }
            QTabWidget::pane { border: 1px solid #d9e2ec; background: white; }
            QTabBar::tab { padding: 9px 18px; background: #d9e2ec; }
            QTabBar::tab:selected { background: white; color: #2368a2; font-weight: 600; }
            QLabel[connected="true"], QLabel[ready="true"] { color: #16803a; font-weight: 700; }
            QLabel[connected="false"], QLabel[ready="false"] { color: #b44; }
        """)

    def append_log(self, message: str) -> None:
        self.log.appendPlainText(f"{time.strftime('%H:%M:%S')}  {message}")

    def connect_serial(self, port: str, baud: int) -> None:
        if self.worker:
            return
        self.worker = SerialWorker(port, baud, self)
        self.worker.connected.connect(self._connection_changed)
        self.worker.response.connect(self._response)
        self.worker.failed.connect(self._request_failed)
        self.worker.finished.connect(self._worker_finished)
        self.connection.connect_button.setEnabled(False)
        self.worker.start()

    def disconnect_serial(self) -> None:
        if self.worker:
            self.worker.stop()
            self.worker.wait(2000)
            self.worker = None
        self.pending.clear()
        self.connection.set_connected(False, "未连接")

    def _connection_changed(self, connected: bool, message: str) -> None:
        self.connection.connect_button.setEnabled(True)
        self.connection.set_connected(connected, message)
        self.append_log(message)
        if connected:
            self.send_request("system:version", Command.READ_VERSION, b"")
        elif self.validation_logger:
            self._finish_validation_batch()

    def _worker_finished(self) -> None:
        self.worker = None
        self.pending.clear()
        self.connection.set_connected(False, "未连接")

    def send_request(self, tag: str, command: int, payload: bytes) -> None:
        if not self.worker or not self.worker.isRunning():
            if not tag.endswith(":poll"):
                self.append_log("请求被忽略：串口未连接")
            return
        if tag in self.pending:
            return
        self.pending.add(tag)
        self.append_log(f"TX {tag} cmd=0x{int(command):02X} payload={payload.hex(' ')}")
        self.worker.submit(tag, int(command), payload)

    def _response(self, tag: str, command: int, payload: bytes) -> None:
        self.pending.discard(tag)
        self.append_log(f"RX {tag} cmd=0x{command:02X} payload={payload.hex(' ')}")
        try:
            if tag.startswith("manual:"):
                self.manual.handle_response(tag, payload)
            elif tag.startswith("autotune:"):
                self.autotune.handle_response(tag, payload)
            elif tag.startswith("validation:"):
                self._validation_response(tag, payload)
            elif tag == "system:version":
                if len(payload) != 1:
                    raise ProtocolError("固件版本响应长度错误")
                self.connection.firmware.setText(f"固件版本：v{payload[0]}")
        except (ProtocolError, ValueError) as exc:
            self._request_failed(tag, str(exc))

    def _request_failed(self, tag: str, message: str) -> None:
        self.pending.discard(tag)
        self.append_log(f"ERROR {tag}: {message}")
        self.statusBar().showMessage(f"{tag}: {message}", 5000)
        if tag.startswith("validation:"):
            self._finish_validation_trial("ERROR", message)

    def start_validation(self, plan_text: str, output_dir: str) -> None:
        if not self.worker or not self.worker.isRunning():
            QMessageBox.warning(self, "验证", "请先连接串口")
            return
        try:
            cases = parse_plan(plan_text)
            self.validation_logger = ValidationLogger(Path(output_dir))
        except Exception as exc:
            QMessageBox.warning(self, "验证计划错误", str(exc))
            return
        self.validation_queue.clear()
        for case in cases:
            for repetition in range(1, case.repeat + 1):
                self.validation_queue.append((case, repetition))
        self.validation.set_running(True)
        self.autotune.auto_poll.setChecked(False)
        self.validation_timer.start()
        self.append_log(f"批次验证开始，共 {len(self.validation_queue)} 次")
        self._begin_validation_trial()

    def _begin_validation_trial(self) -> None:
        if not self.validation_queue:
            self._finish_validation_batch()
            return
        self.validation_case, self.validation_repeat = self.validation_queue.popleft()
        self.validation_deadline = time.monotonic() + self.validation_case.timeout_s
        self.validation_phase = "configure_center"
        self._write_record("START_CASE", note=self.validation_case.note)
        self._validation_advance()

    def _validation_advance(self) -> None:
        case = self.validation_case
        if case is None:
            return
        prefix = "freq" if case.target is LoopTarget.FREQ else "dpll"
        if self.validation_phase == "configure_center":
            if case.center_frequency is not None:
                command = Command.WRITE_FREQ_CENTER if case.target is LoopTarget.FREQ else Command.WRITE_DPLL_CENTER
                self.validation_phase = "wait_center"
                self.send_request("validation:center", command, pack_u32(case.center_frequency))
                return
            self.validation_phase = "configure_pid"
        if self.validation_phase == "configure_pid":
            if case.pid is not None:
                command = Command.WRITE_FREQ_PID if case.target is LoopTarget.FREQ else Command.WRITE_DPLL_PID
                self.validation_phase = "wait_pid"
                self.send_request("validation:pid", command, pack_pid(*case.pid))
                return
            self.validation_phase = "start_autotune"
        if self.validation_phase == "start_autotune":
            if case.autotune:
                self.validation_phase = "wait_start"
                self.send_request("validation:start", case.target.command, pack_autotune(AutotuneAction.START))
                return
            self._finish_validation_trial("CONFIGURED")

    def _validation_response(self, tag: str, payload: bytes) -> None:
        case = self.validation_case
        if case is None:
            return
        if tag == "validation:center":
            unpack_ack(payload)
            self.validation_phase = "configure_pid"
            self._validation_advance()
        elif tag == "validation:pid":
            unpack_ack(payload)
            self.validation_phase = "start_autotune"
            self._validation_advance()
        elif tag in {"validation:start", "validation:query", "validation:cancel"}:
            status = unpack_autotune(payload)
            card = self.autotune.freq if case.target is LoopTarget.FREQ else self.autotune.dpll
            card.update_status(status)
            self._write_record("QUERY" if tag == "validation:query" else tag.split(":")[1].upper(), status)
            if tag == "validation:start":
                if status.result_name == "BUSY":
                    self._finish_validation_trial("FAILED", "全局仲裁器忙")
                else:
                    self.validation_phase = "poll"
            elif tag == "validation:query":
                if status.done:
                    self._finish_validation_trial("DONE", status=status)
                elif status.failed or (not status.busy and status.exec_name in {"FAILED", "CANCELED"}):
                    self._finish_validation_trial("FAILED", status.result_name, status)

    def _validation_tick(self) -> None:
        case = self.validation_case
        if case is None:
            return
        if time.monotonic() > self.validation_deadline:
            self.send_request("validation:cancel", case.target.command, pack_autotune(AutotuneAction.CANCEL))
            self._finish_validation_trial("FAILED", "验证超时")
            return
        if self.validation_phase == "poll":
            self.send_request("validation:query", case.target.command, pack_autotune(AutotuneAction.QUERY))

    def _write_record(self, event: str, status: AutotuneStatus | None = None, note: str = "") -> None:
        case = self.validation_case
        if case is None:
            return
        record = RunRecord(
            timestamp=timestamp_now(), case_name=case.name, target=case.target.name.lower(),
            repetition=self.validation_repeat, event=event,
            run_id=status.run_id if status else None, progress=status.progress if status else None,
            exec_state=status.exec_name if status else "", health_state=status.health_name if status else "",
            result=status.result_name if status else "", current_profile=status.current_profile if status else None,
            active_profile=status.active_profile if status else None, best_profile=status.best_profile if status else None,
            current_score=status.current_score if status else None, best_score=status.best_score if status else None,
            elapsed_ms=status.elapsed_ms if status else None, note=note,
        )
        self.validation.model.append(record)
        if self.validation_logger:
            self.validation_logger.write(record)

    def _finish_validation_trial(self, event: str, note: str = "", status: AutotuneStatus | None = None) -> None:
        self._write_record(event, status, note)
        self.validation_case = None
        self.validation_phase = "idle"
        QTimer.singleShot(500, self._begin_validation_trial)

    def stop_validation(self) -> None:
        if self.validation_case and self.validation_case.autotune:
            self.send_request("validation:cancel", self.validation_case.target.command, pack_autotune(AutotuneAction.CANCEL))
        self.validation_queue.clear()
        self._finish_validation_batch()

    def _finish_validation_batch(self) -> None:
        self.validation_timer.stop()
        self.validation_case = None
        self.validation_phase = "idle"
        if self.validation_logger:
            self.append_log(f"日志已保存：{self.validation_logger.csv_path} / {self.validation_logger.jsonl_path}")
            self.validation_logger.close()
            self.validation_logger = None
        self.validation.set_running(False)
        self.autotune.auto_poll.setChecked(True)
        self.append_log("批次验证结束")

    def closeEvent(self, event) -> None:
        self.stop_validation()
        self.disconnect_serial()
        super().closeEvent(event)


def run() -> int:
    app = QApplication(sys.argv)
    app.setApplicationName("DPLL Autotune Host")
    app.setFont(QFont("Microsoft YaHei UI", 10))
    window = MainWindow()
    window.show()
    return app.exec()
