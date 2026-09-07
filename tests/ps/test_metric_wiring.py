"""Check the production tops' register/CDC contract against the extended HAL.

Complements the behavioral RTL and mocked-MMIO tests: those do not elaborate
the complete legacy design with its generated vendor IP.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "DPLL_Rewrite.srcs/sources_1"
FIELDS = [
    ("freq_signed_sum", 64), ("freq_square_sum", 64),
    ("phase_signed_sum", 64), ("phase_first", 32), ("phase_last", 32),
    ("residual_bad_samples", 32), ("rail_samples", 32), ("phase_sat_samples", 32),
]


class WiringTests(unittest.TestCase):
    def test_registers(self):
        expected = [(0x136, "32'hAD050001")]
        address = 0x137
        for field, width in FIELDS:
            for word in range(width // 32):
                value = "adaptive_" + field
                if width == 64:
                    value += "[31:0]" if word == 0 else "[63:32]"
                expected.append((address, value))
                address += 1
        for name in ("Freq_Meter/Digital_Freq_Meter.v", "DigitalPLL/dpll_wrapper.v"):
            text = (SOURCES / name).read_bytes().decode("latin1")
            for address, value in expected:
                with self.subTest(top=name, address=hex(address)):
                    pattern = rf"16'h{address:04X}\s*:.*?sys_rdata <= {re.escape(value)};"
                    self.assertEqual(len(re.findall(pattern, text)), 1)

    def test_cdc_bundle(self):
        text = (SOURCES / "DigitalPLL/dpll_wrapper.v").read_bytes().decode("latin1")
        source = re.search(r"assign adaptive_snapshot_source_bundle = \{(.*?)\};", text, re.S)[1]
        destination = re.search(r"assign \{(.*?)\} = adaptive_snapshot_bus_bundle;", text, re.S)[1]
        source = [n.strip().removesuffix("_loop") for n in source.split(",")]
        destination = [n.strip() for n in destination.split(",")]
        self.assertEqual(source, destination)
        self.assertEqual(len(source), len(set(source)))
        widths = {n.strip(): int(w) + 1 for w, names in
                  re.findall(r"wire \[(\d+):0\] ([^;]+);", text)
                  for n in names.split(",")}
        self.assertEqual(sum(widths[n] for n in destination), 1024)
        self.assertEqual(destination[-len(FIELDS):], ["adaptive_" + f for f, _ in FIELDS])
        self.assertIn(".DATA_WIDTH(1024)", text)


if __name__ == "__main__":
    unittest.main()
