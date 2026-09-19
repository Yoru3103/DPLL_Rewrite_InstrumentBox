import unittest

try:
    from dpll_host.transport import SerialWorker
except ImportError:
    SerialWorker = None

from dpll_host.protocol import StreamDecoder, checksum
from test_autotune_v2 import status_payload, diagnostic_page


def response(payload):
    return bytes((0xa2, checksum(0x97, payload), 0x97, len(payload))) + payload


class FakeSerial:
    def __init__(self, chunks):
        self.chunks = list(chunks)

    @property
    def in_waiting(self):
        return len(self.chunks[0]) if self.chunks else 0

    def read(self, count):
        return self.chunks.pop(0) if self.chunks else b''


@unittest.skipIf(SerialWorker is None, 'Qt/serial dependencies unavailable')
class AutotuneTransportTests(unittest.TestCase):
    def test_late_query_is_not_accepted_as_start(self):
        device = FakeSerial([response(status_payload(action=0)), response(status_payload(action=1, busy=True))])
        frame = SerialWorker._wait_for_frame(device, StreamDecoder(), 0x97, .1, b'\x01')
        self.assertEqual(frame.payload[1], 1)

    def test_late_page_and_other_action_are_skipped(self):
        device = FakeSerial([response(status_payload()), response(diagnostic_page(0)), response(diagnostic_page(1))])
        frame = SerialWorker._wait_for_frame(device, StreamDecoder(), 0x97, .1, b'\x05\x01')
        self.assertEqual(frame.payload, diagnostic_page(1))

    def test_diagnostic_rejection_reaches_caller(self):
        rejected = status_payload(action=5, result=5)
        device = FakeSerial([response(rejected)])
        frame = SerialWorker._wait_for_frame(device, StreamDecoder(), 0x97, .1, b'\x05\x01')
        self.assertEqual(frame.payload, rejected)


if __name__ == '__main__':
    unittest.main()
