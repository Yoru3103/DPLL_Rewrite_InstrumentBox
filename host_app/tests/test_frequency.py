import unittest

from dpll_host.protocol import ProtocolError, unpack_frequency, center_mhz_to_word, center_word_to_mhz


class FrequencyTests(unittest.TestCase):
    def test_center_units(self):
        for text in ("40", "40MHz", " 40 mhz ", "40.0"):
            self.assertEqual(center_mhz_to_word(text), 1374389535)
        for word in (0, 1, 1374389534, 1374389535, 0xFFFFFFFF):
            self.assertEqual(center_mhz_to_word(center_word_to_mhz(word)), word)

    def test_invalid_center(self):
        for text in ("", "NaN", "Infinity", "-1", "125", "40000000", "40Hz"):
            with self.assertRaises(ValueError):
                center_mhz_to_word(text)

    def test_quarter_clock_frequency(self):
        for gate in (125_000, 125_000_000):
            payload = ((1 << 31) * gate).to_bytes(10, "little") + gate.to_bytes(6, "little")
            self.assertEqual(unpack_frequency(payload), 31_250_000.0)

    def test_invalid_measurement(self):
        for payload in (b"", bytes(15), bytes(16), bytes(17)):
            with self.assertRaises(ProtocolError):
                unpack_frequency(payload)
