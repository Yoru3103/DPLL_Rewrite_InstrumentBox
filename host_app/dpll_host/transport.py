from __future__ import annotations

from dataclasses import dataclass
from queue import Empty, Queue
import time

from PyQt6.QtCore import QThread, pyqtSignal
import serial

from .protocol import Frame, StreamDecoder, pack_request


@dataclass(frozen=True)
class Request:
    tag: str
    command: int
    payload: bytes
    timeout_s: float = 1.5


class SerialWorker(QThread):
    connected = pyqtSignal(bool, str)
    response = pyqtSignal(str, int, bytes)
    failed = pyqtSignal(str, str)

    def __init__(self, port: str, baudrate: int = 921600, parent=None) -> None:
        super().__init__(parent)
        self.port = port
        self.baudrate = baudrate
        self._requests: Queue[Request | None] = Queue()
        self._running = True

    def submit(self, tag: str, command: int, payload: bytes = b"", timeout_s: float = 1.5) -> None:
        self._requests.put(Request(tag, command, payload, timeout_s))

    def stop(self) -> None:
        self._running = False
        self._requests.put(None)

    def run(self) -> None:
        try:
            device = serial.Serial(
                self.port,
                self.baudrate,
                timeout=0.05,
                write_timeout=1.0,
            )
        except Exception as exc:
            self.connected.emit(False, str(exc))
            return

        decoder = StreamDecoder()
        try:
            device.reset_input_buffer()
            device.reset_output_buffer()
            self.connected.emit(True, self.port)
            while self._running:
                try:
                    request = self._requests.get(timeout=0.1)
                except Empty:
                    continue
                if request is None:
                    break
                try:
                    device.write(pack_request(request.command, request.payload))
                    device.flush()
                    frame = self._wait_for_frame(device, decoder, request.command, request.timeout_s)
                    self.response.emit(request.tag, frame.command, frame.payload)
                except Exception as exc:
                    self.failed.emit(request.tag, str(exc))
        finally:
            device.close()
            self.connected.emit(False, "串口已关闭")

    @staticmethod
    def _wait_for_frame(device: serial.Serial, decoder: StreamDecoder, command: int, timeout_s: float) -> Frame:
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            data = device.read(max(device.in_waiting, 1))
            for frame in decoder.feed(data):
                if frame.command == command:
                    return frame
        raise TimeoutError(f"等待命令 0x{command:02X} 响应超时")
