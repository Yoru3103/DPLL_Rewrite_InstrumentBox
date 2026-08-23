import struct
import unittest

from dpll_host.protocol import (
    AutotuneAction, Command, StreamDecoder, checksum, pack_autotune,
    ProtocolError, pack_pid, pack_request, parse_response, unpack_ack,
    unpack_autotune, unpack_pid,
)


class ProtocolTests(unittest.TestCase):
    def test_request_frame(self):
        frame = pack_request(Command.AUTOTUNE_FREQ, pack_autotune(AutotuneAction.START))
        self.assertEqual(frame, bytes((0xC6, 0x99, 0x97, 0x01, 0x01)))

    def test_pid_round_trip(self):
        values = (1, 2, 3, 0xFFFFFFFF)
        self.assertEqual(unpack_pid(pack_pid(*values)), values)

    def test_ack_rejection(self):
        self.assertEqual(unpack_ack(b"\x00"), 0)
        with self.assertRaises(ProtocolError):
            unpack_ack(b"\x03")

    def test_autotune_status(self):
        status_word = (7 << 24) | (1 << 16) | (1 << 12) | (11 << 8) | 0x19
        payload = bytes((1, 0)) + struct.pack("<I", status_word) + bytes((100, 4, 4, 4))
        payload += struct.pack("<HHI", 123, 100, 4567)
        status = unpack_autotune(payload)
        self.assertTrue(status.done)
        self.assertTrue(status.params_valid)
        self.assertTrue(status.lock_valid)
        self.assertTrue(status.adapt_ready)
        self.assertEqual(status.run_id, 7)
        self.assertEqual(status.exec_name, "DONE")

    def test_stream_decoder_skips_debug_text(self):
        payload = b"\x02"
        raw = bytes((0xA2, checksum(0x0A, payload), 0x0A, 1)) + payload
        decoder = StreamDecoder()
        self.assertEqual(decoder.feed(b"OK_0x0AR\r\n" + raw[:2]), [])
        frames = decoder.feed(raw[2:])
        self.assertEqual(frames[0], parse_response(raw))


if __name__ == "__main__":
    unittest.main()
