from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum
import struct
from decimal import Decimal, InvalidOperation


REQUEST_HEAD = 0xC6
RESPONSE_HEAD = 0xA2
MAX_PAYLOAD = 48


def center_mhz_to_word(text: str) -> int:
    value = text.strip().lower()
    if value.endswith("mhz"):
        value = value[:-3].strip()
    try:
        frequency = Decimal(value)
    except InvalidOperation:
        raise ValueError("请输入 MHz 数值，例如 40、40.5 或 40MHz") from None
    if not frequency.is_finite() or not Decimal(0) <= frequency < Decimal(125):
        raise ValueError("中心频率必须满足 0 ≤ MHz < 125（125 MHz 时钟）")
    word = round(frequency * (1 << 32) / Decimal(125))
    if word > 0xFFFFFFFF:
        raise ValueError("中心频率超过 32 位频率控制字可表示的上限")
    return word


def center_word_to_mhz(value: int) -> str:
    return f"{Decimal(value) * 125 / (1 << 32):.9f}"


class Command(IntEnum):
    READ_DPLL_CENTER = 0x03
    READ_DPLL_PID = 0x07
    READ_DPLL_STATUS = 0x09
    READ_VERSION = 0x0A
    READ_FREQ_CENTER = 0x10
    READ_FREQ_PID = 0x13
    READ_FREQ_STATUS = 0x14
    READ_FREQ_RUN_STATUS = 0x15
    READ_FREQ_COUNT = 0x17
    WRITE_FREQ_TIMER = 0x94
    FREQ_TRIGGER = 0x95
    WRITE_DPLL_CENTER = 0x82
    WRITE_DPLL_PID = 0x86
    DPLL_ON = 0x8A
    DPLL_OFF = 0x8B
    WRITE_FREQ_CENTER = 0x90
    WRITE_FREQ_PID = 0x93
    FREQ_RESET = 0x96
    AUTOTUNE_FREQ = 0x97
    AUTOTUNE_DPLL = 0x98


class LoopTarget(IntEnum):
    FREQ = 0
    DPLL = 1

    @property
    def command(self) -> Command:
        return Command.AUTOTUNE_FREQ if self is LoopTarget.FREQ else Command.AUTOTUNE_DPLL


class AutotuneAction(IntEnum):
    QUERY = 0
    START = 1
    CANCEL = 2
    CLEAR = 3
    SET_POLICY = 4


class AutotunePolicy(IntEnum):
    HOST_ONLY = 0
    BOOT_ONCE = 1
    BOOT_AND_RECOVER = 2


EXEC_STATE_NAMES = {
    0: "IDLE", 1: "PRECHECK", 2: "BASELINE", 3: "APPLY_CANDIDATE",
    4: "SETTLE", 5: "EVALUATE", 6: "NEXT_CANDIDATE", 7: "SELECT_BEST",
    8: "APPLY_BEST", 9: "VERIFY", 10: "ROLLBACK", 11: "DONE",
    12: "FAILED", 13: "CANCELED",
}
HEALTH_STATE_NAMES = {
    0: "UNINITIALIZED", 1: "VALID", 2: "DEGRADED", 3: "LOST",
    4: "RETUNE_PENDING", 5: "FAULT",
}
RESULT_NAMES = {
    0: "NONE", 1: "SUCCESS", 2: "ACCEPTED", 3: "BUSY", 4: "REJECTED",
    5: "INVALID_ACTION", 6: "INVALID_POLICY", 7: "NOT_LOCKED",
    8: "READBACK_ERROR", 9: "CANCELED",
}
PROFILE_NAMES = {
    0: "ORIGINAL", 1: "SAFE", 2: "TRACK_WEAK", 3: "TRACK_MEDIUM",
    4: "TRACK_STRONG", 5: "ACQUIRE", 0xFF: "NONE",
}


def profile_name(profile_id: int) -> str:
    return PROFILE_NAMES.get(profile_id, f"UNKNOWN({profile_id})")


class ProtocolError(RuntimeError):
    pass


@dataclass(frozen=True)
class Frame:
    command: int
    payload: bytes


@dataclass(frozen=True)
class AutotuneStatus:
    protocol_version: int
    action: int
    status_word: int
    progress: int
    current_profile: int
    active_profile: int
    best_profile: int
    current_score: int
    best_score: int
    elapsed_ms: int

    @property
    def done(self) -> bool:
        return bool(self.status_word & (1 << 0))

    @property
    def busy(self) -> bool:
        return bool(self.status_word & (1 << 1))

    @property
    def failed(self) -> bool:
        return bool(self.status_word & (1 << 2))

    @property
    def params_valid(self) -> bool:
        return bool(self.status_word & (1 << 3))

    @property
    def lock_valid(self) -> bool:
        return bool(self.status_word & (1 << 4))

    @property
    def adapt_ready(self) -> bool:
        return self.done and self.params_valid and self.lock_valid

    @property
    def exec_state(self) -> int:
        return (self.status_word >> 8) & 0x0F

    @property
    def health_state(self) -> int:
        return (self.status_word >> 12) & 0x0F

    @property
    def result_code(self) -> int:
        return (self.status_word >> 16) & 0xFF

    @property
    def run_id(self) -> int:
        return (self.status_word >> 24) & 0xFF

    @property
    def exec_name(self) -> str:
        return EXEC_STATE_NAMES.get(self.exec_state, f"UNKNOWN({self.exec_state})")

    @property
    def health_name(self) -> str:
        return HEALTH_STATE_NAMES.get(self.health_state, f"UNKNOWN({self.health_state})")

    @property
    def result_name(self) -> str:
        return RESULT_NAMES.get(self.result_code, f"UNKNOWN({self.result_code})")


def checksum(command: int, payload: bytes) -> int:
    return (command + len(payload) + sum(payload)) & 0xFF


def pack_request(command: int | Command, payload: bytes = b"") -> bytes:
    if len(payload) > MAX_PAYLOAD:
        raise ValueError(f"payload too long: {len(payload)}")
    command_value = int(command)
    return bytes((REQUEST_HEAD, checksum(command_value, payload), command_value, len(payload))) + payload


def parse_response(frame: bytes) -> Frame:
    if len(frame) < 4:
        raise ProtocolError("response shorter than header")
    if frame[0] != RESPONSE_HEAD:
        raise ProtocolError(f"invalid response head 0x{frame[0]:02X}")
    size = frame[3]
    if len(frame) != size + 4:
        raise ProtocolError(f"response length mismatch: header={size}, actual={len(frame) - 4}")
    payload = frame[4:]
    if frame[1] != checksum(frame[2], payload):
        raise ProtocolError("response checksum mismatch")
    return Frame(frame[2], payload)


def pack_u32(value: int) -> bytes:
    if not 0 <= value <= 0xFFFFFFFF:
        raise ValueError("value must fit uint32")
    return struct.pack("<I", value)


def unpack_frequency(payload: bytes) -> float:
    if len(payload) != 16:
        raise ProtocolError("测频结果长度应为 16 字节")
    phase_sum = int.from_bytes(payload[:10], "little")
    gate_clocks = int.from_bytes(payload[10:], "little")
    if gate_clocks == 0:
        raise ProtocolError("测频门控时间为零，请重新测量")
    return phase_sum * 125_000_000 / (gate_clocks * (1 << 33))


def unpack_u32(payload: bytes, offset: int = 0) -> int:
    if len(payload) < offset + 4:
        raise ProtocolError("uint32 field truncated")
    return struct.unpack_from("<I", payload, offset)[0]


def unpack_ack(payload: bytes) -> int:
    if len(payload) != 1:
        raise ProtocolError(f"ACK response must be 1 byte, got {len(payload)}")
    if payload[0] != 0:
        raise ProtocolError(f"device rejected command, code={payload[0]}")
    return payload[0]


def pack_pid(kp: int, ki: int, kii: int, kd: int) -> bytes:
    return b"".join(pack_u32(value) for value in (kp, ki, kii, kd))


def unpack_pid(payload: bytes) -> tuple[int, int, int, int]:
    if len(payload) != 16:
        raise ProtocolError(f"PID response must be 16 bytes, got {len(payload)}")
    return struct.unpack("<IIII", payload)


def pack_autotune(action: AutotuneAction, policy: AutotunePolicy | None = None) -> bytes:
    payload = bytes((int(action),))
    if action is AutotuneAction.SET_POLICY:
        if policy is None:
            raise ValueError("SET_POLICY requires policy")
        payload += bytes((int(policy),))
    return payload


def unpack_autotune(payload: bytes) -> AutotuneStatus:
    if len(payload) != 18:
        raise ProtocolError(f"autotune response must be 18 bytes, got {len(payload)}")
    return AutotuneStatus(
        protocol_version=payload[0],
        action=payload[1],
        status_word=unpack_u32(payload, 2),
        progress=payload[6],
        current_profile=payload[7],
        active_profile=payload[8],
        best_profile=payload[9],
        current_score=struct.unpack_from("<H", payload, 10)[0],
        best_score=struct.unpack_from("<H", payload, 12)[0],
        elapsed_ms=unpack_u32(payload, 14),
    )


class StreamDecoder:
    """Incremental response decoder that ignores UART debug text before 0xA2."""

    def __init__(self) -> None:
        self._buffer = bytearray()

    def feed(self, data: bytes) -> list[Frame]:
        self._buffer.extend(data)
        frames: list[Frame] = []
        while True:
            try:
                head = self._buffer.index(RESPONSE_HEAD)
            except ValueError:
                self._buffer.clear()
                break
            if head:
                del self._buffer[:head]
            if len(self._buffer) < 4:
                break
            size = self._buffer[3]
            if size > MAX_PAYLOAD:
                del self._buffer[0]
                continue
            total = size + 4
            if len(self._buffer) < total:
                break
            raw = bytes(self._buffer[:total])
            del self._buffer[:total]
            try:
                frames.append(parse_response(raw))
            except ProtocolError:
                continue
        return frames
