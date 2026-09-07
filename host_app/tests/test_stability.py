import json
import tempfile
import unittest
from unittest.mock import patch

from dpll_host.protocol import Command, pack_pid, ProtocolError
from dpll_host.stability import (StabilityRun, Settings, Canceled, parse_profiles,
                                 summarize, rank_results)


class FakeBoard:
    def __init__(self):
        self.pid = (11, 22, 33, 44)
        self.gate = (12345).to_bytes(6, "little")
        self.triggers = 0
        self.reads = 0
        self.commands = []
        self.locked = True

    def response(self, cmd, payload):
        self.commands.append(cmd)
        if cmd in (Command.AUTOTUNE_FREQ, Command.AUTOTUNE_DPLL):
            return bytes([1, 0]) + bytes(16)
        if cmd == Command.READ_FREQ_RUN_STATUS:
            return b"\x00"
        if cmd == Command.READ_FREQ_PID:
            return pack_pid(*self.pid)
        if cmd == Command.READ_FREQ_CENTER:
            return (123).to_bytes(4, "little")
        if cmd == 0x16:
            return self.gate
        if cmd == Command.READ_FREQ_STATUS:
            return bytes(6) + bytes([0x30 if self.locked else 0x20])
        if cmd == Command.WRITE_FREQ_TIMER:
            self.gate = payload
        elif cmd == Command.WRITE_FREQ_PID:
            self.pid = tuple(int.from_bytes(payload[i:i+4], "little") for i in range(0, 16, 4))
        elif cmd == Command.FREQ_TRIGGER:
            self.triggers += 1
        elif cmd == Command.READ_FREQ_COUNT:
            self.reads += 1
            return ((40_000_000 + self.reads % 2) * (1 << 33)).to_bytes(10, "little") + self.gate
        else:
            raise AssertionError(cmd)
        return b"\x00"


def drive(sequence, board, hook=None):
    item = next(sequence)
    for _ in range(10000):
        cmd, payload, delay = item
        response = None if cmd is None else board.response(cmd, payload)
        if hook:
            response = hook(cmd, payload, response)
        try:
            item = sequence.send(response)
        except StopIteration:
            return
    raise AssertionError("sequence did not terminate")


class StabilityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.run = StabilityRun([("original", None), ("test", (1, 2, 0, 0))],
                                Settings(0, 3, 2), self.tmp.name)
        self.board = FakeBoard()

    def tearDown(self):
        self.run.close()
        self.tmp.cleanup()

    def test_statistics(self):
        r = summarize([39, 40, 41], 40)
        self.assertEqual(r["mean_hz"], 40)
        self.assertEqual(r["std_hz"], 1)
        self.assertEqual(r["p2p_hz"], 2)
        self.assertEqual(r["offset_hz"], 0)

    def test_invalid_samples(self):
        for values in ([1], [float("nan"), 2]):
            with self.assertRaises(ValueError):
                summarize(values, 40)

    def test_plan_validation(self):
        self.assertEqual(parse_profiles('[{"name":"x","pid":["0x10",2,0,0]}]')[0][1], (16, 2, 0, 0))
        for value in ("[]", '[{"name":"a"},{"name":"a"}]', '[{"name":"a","pid":[1]}]'):
            with self.assertRaises(ValueError):
                parse_profiles(value)

    def test_complete_and_restore(self):
        drive(self.run.sequence(), self.board)
        self.assertEqual(self.board.reads, 12)
        self.assertEqual(self.board.triggers, self.board.reads)
        self.assertEqual(self.board.pid, (11, 22, 33, 44))
        self.assertEqual(self.board.gate, (12345).to_bytes(6, "little"))
        self.assertTrue(self.run.restored)
        self.assertEqual(len(self.run.rows), 4)
        self.assertEqual(len(rank_results(self.run.rows, 2)), 2)
        self.assertEqual(len(rank_results(self.run.rows[:1], 2)), 0)
        events = [json.loads(line) for line in self.run.event_path.read_text().splitlines()]
        self.assertEqual(events[-1]["event"], "RESTORED")

    def test_unlocked_precheck_does_not_write(self):
        self.board.locked = False
        with self.assertRaises(ProtocolError):
            drive(self.run.sequence(), self.board)
        self.assertNotIn(Command.WRITE_FREQ_PID, self.board.commands)
        self.assertFalse(self.run.changed)

    def test_lock_loss_restores_without_ranking(self):
        def hook(cmd, payload, response):
            if cmd == Command.READ_FREQ_COUNT:
                self.board.locked = False
            return response
        with self.assertRaises(ProtocolError):
            drive(self.run.sequence(), self.board, hook)
        self.assertTrue(self.run.restored)
        self.assertEqual(self.run.rows, [])

    def test_readback_error_restores(self):
        def hook(cmd, payload, response):
            if cmd == Command.READ_FREQ_PID and self.run.changed and not self.run.restoring:
                return pack_pid(999, 0, 0, 0)
            return response
        with self.assertRaises(ProtocolError):
            drive(self.run.sequence(), self.board, hook)
        self.assertTrue(self.run.restored)

    def test_cancel_during_wait(self):
        seq = self.run.sequence()
        item = next(seq)
        while item[0] is not None:
            item = seq.send(self.board.response(item[0], item[1]))
        item = seq.throw(Canceled("stop"))
        with self.assertRaises(Canceled):
            while True:
                cmd, payload, delay = item
                item = seq.send(None if cmd is None else self.board.response(cmd, payload))
        self.assertTrue(self.run.restored)

    def test_restore_failure_is_not_success(self):
        def hook(cmd, payload, response):
            if self.run.restoring and cmd == Command.READ_FREQ_PID:
                return pack_pid(0, 0, 0, 0)
            return response
        with self.assertRaises(ProtocolError):
            drive(self.run.sequence(), self.board, hook)
        self.assertFalse(self.run.restored)

    def test_gate_mismatch(self):
        def hook(cmd, payload, response):
            if cmd == Command.READ_FREQ_COUNT:
                return response[:10] + (42).to_bytes(6, "little")
            return response
        with self.assertRaises(ProtocolError):
            drive(self.run.sequence(), self.board, hook)
        self.assertTrue(self.run.restored)

    def test_autotune_busy_rejected(self):
        def hook(cmd, payload, response):
            if cmd == Command.AUTOTUNE_FREQ:
                return response[:2] + bytes([2]) + response[3:]
            return response
        with self.assertRaises(ProtocolError):
            drive(self.run.sequence(), self.board, hook)
        self.assertFalse(self.run.changed)

    def test_transport_error_attempts_restore(self):
        seq = self.run.sequence()
        item = next(seq)
        while not self.run.changed:
            item = seq.send(self.board.response(item[0], item[1]))
        # An ACK may be lost after hardware accepted this first write.
        self.board.response(item[0], item[1])
        item = seq.throw(TimeoutError("ACK lost"))
        with self.assertRaises(TimeoutError):
            while True:
                cmd, payload, delay = item
                item = seq.send(None if cmd is None else self.board.response(cmd, payload))
        self.assertTrue(self.run.restored)

    def test_measurement_timeout(self):
        def hook(cmd, payload, response):
            if cmd == Command.READ_FREQ_RUN_STATUS and self.board.triggers and not self.run.restoring:
                return b"\x01"
            return response
        with patch("dpll_host.stability.time.monotonic", side_effect=[0, 6, 7]):
            with self.assertRaises(ProtocolError):
                drive(self.run.sequence(), self.board, hook)
        self.assertTrue(self.run.restored)

    def test_close_on_transport_loss_has_no_more_writes(self):
        seq = self.run.sequence()
        item = next(seq)
        while item[0] is not None:
            item = seq.send(self.board.response(item[0], item[1]))
        count = len(self.board.commands)
        seq.close()
        self.assertEqual(count, len(self.board.commands))
        self.assertFalse(self.run.restored)


if __name__ == "__main__":
    unittest.main()
