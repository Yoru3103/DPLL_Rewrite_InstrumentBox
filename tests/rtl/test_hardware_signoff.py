"""Finite-slack regression for the production Vivado Tcl release gate."""
from pathlib import Path
import tkinter
import unittest

ROOT = Path(__file__).resolve().parents[2]


class HardwareSignoff(unittest.TestCase):
    def test_production_finite_path_gate(self):
        source = (ROOT / "tests/rtl/finalize_autotune_hardware.tcl").read_text()
        gate = source[source.index("proc at_assert_paths"):source.index("at_assert_paths $first_holds")]
        interpreter = tkinter.Tcl()
        interpreter.eval("proc get_property {name path} {return $path}")
        interpreter.eval(gate)
        for pair in [("0.034", "0.8"), ("0", "2.5e-2")]:
            interpreter.call("at_assert_paths", pair, 2, "test paths")
        for pair in [("inf", "0.8"), ("Inf", "0.8"), ("-inf", "0.8"), ("NaN", "0.8"), ("", "0.8"), ("-0.001", "0.8"), ("0.8",)]:
            with self.subTest(pair=pair), self.assertRaises(tkinter.TclError):
                interpreter.call("at_assert_paths", pair, 2, "test paths")


if __name__ == "__main__":
    unittest.main()
