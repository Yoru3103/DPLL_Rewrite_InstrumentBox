import unittest

from dpll_host.protocol import LoopTarget
from dpll_host.validation import default_plan_text, parse_plan


class ValidationPlanTests(unittest.TestCase):
    def test_default_plan(self):
        cases = parse_plan(default_plan_text())
        self.assertEqual(cases[0].target, LoopTarget.FREQ)
        self.assertEqual(cases[1].target, LoopTarget.DPLL)
        self.assertEqual(cases[0].repeat, 3)
        self.assertEqual(cases[0].timeout_s, 150)
        self.assertEqual(cases[1].timeout_s, 150)

    def test_hex_values(self):
        cases = parse_plan('[{"name":"x","target":"dpll","center_frequency":"0x10",'
                           '"pid":["0x1",2,3,4]}]')
        self.assertEqual(cases[0].center_frequency, 16)
        self.assertEqual(cases[0].pid, (1, 2, 3, 4))

    def test_invalid_target(self):
        with self.assertRaises(ValueError):
            parse_plan('[{"name":"x","target":"bad"}]')


if __name__ == "__main__":
    unittest.main()
