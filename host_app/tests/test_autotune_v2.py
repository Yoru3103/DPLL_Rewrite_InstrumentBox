import json
import struct
import tempfile
import unittest
from pathlib import Path

from dpll_host.autotune_diagnostics import (AutotuneConfig, DiagnosticBatch,
    DiagnosticLogger, DIAGNOSTIC_PAGES, diagnostic_request, unpack_config)
from dpll_host.protocol import ProtocolError, unpack_autotune


def status_payload(version=2, action=0, result=1, busy=False):
    word = (5 << 24) | (result << 16) | ((5 if busy else 11) << 8) | (2 if busy else 0x19)
    return bytes((version, action)) + struct.pack('<I', word) + bytes((50, 1, 1, 1)) + struct.pack('<HHI', 1234, 1000, 5000)


def config_payload(config=AutotuneConfig()):
    return b'\x02\x06\x00\x00' + config.pack()[1:]


def diagnostic_page(page, report_id=7, run_id=5, profile=1):
    header = bytes((2, 5, page, run_id)) + struct.pack('<I', report_id) + bytes((1, profile, 0, 7))
    if page in (2, 3, 4, 6):
        values = [float(i + 1) for i in range(8)]
        if page == 3:
            values[5:8] = [0.92, 1.0, 0.01]
        return header + struct.pack('<8f', *values)
    values = list(range(8))
    if page == 0:
        values = [0, 1234, 3, 1200, 10, 0, 1000, 33]
    elif page == 1:
        values[0] = 2
    elif page == 5:
        values[1] = 0xfffffffd
    elif page == 7:
        values = [1000, 3, 800, 16, 30, 125000000, 4096, 300]
    elif page == 8:
        values = [0xfffffff0, 0xfffff000, 4096, 3, 1, 0, 0, 0]
    return header + struct.pack('<8I', *values)


class AutotuneV2ProtocolTests(unittest.TestCase):
    def test_old_and_new_status(self):
        for version in (1, 2):
            status = unpack_autotune(status_payload(version, result=12))
            self.assertEqual(status.protocol_version, version)
            self.assertEqual(status.result_name, 'NO_IMPROVEMENT')
        with self.assertRaises(ProtocolError):
            unpack_autotune(status_payload(3))

    def test_config_wire_format_and_limits(self):
        config = AutotuneConfig()
        self.assertEqual(config.pack(), b'\x07' + struct.pack('<5I', 1000, 3, 800, 16, 30))
        self.assertEqual(unpack_config(config_payload()), config)
        for config in (AutotuneConfig(window_ms=999), AutotuneConfig(window_ms=2000, repeats=4),
                       AutotuneConfig(repeats=1), AutotuneConfig(coverage_permille=799),
                       AutotuneConfig(amplitude_floor=0), AutotuneConfig(improvement_permille=501)):
            with self.assertRaises(ValueError):
                config.pack()
        with self.assertRaises(ProtocolError):
            unpack_config(b'\x01' + config_payload()[1:])

    def test_complete_frozen_report_preserves_sample_width_and_signed_values(self):
        batch = DiagnosticBatch()
        for page in range(DIAGNOSTIC_PAGES - 1):
            self.assertIsNone(batch.add(diagnostic_page(page)))
        report = batch.add(diagnostic_page(DIAGNOSTIC_PAGES - 1))
        self.assertEqual(report['metrics']['samples'], (2 << 32) + 33)
        self.assertEqual(report['metrics']['output_min'], -3)
        self.assertEqual(report['metrics']['phase_offset'], -16)
        self.assertEqual(report['metrics']['output_low'], -4096)
        self.assertEqual(report['metrics']['clock_hz'], 125000000)
        self.assertTrue(report['qualified'])
        self.assertEqual(len(report['raw_pages_hex']), 9)

    def test_mixed_missing_duplicate_and_nonfinite_pages_rejected(self):
        for bad in (diagnostic_page(1, report_id=8), diagnostic_page(1, run_id=6),
                    diagnostic_page(1, profile=2), diagnostic_page(0), diagnostic_page(2)):
            batch = DiagnosticBatch()
            batch.add(diagnostic_page(0))
            with self.assertRaises(ProtocolError):
                batch.add(bad)
        batch = DiagnosticBatch()
        batch.add(diagnostic_page(0))
        batch.add(diagnostic_page(1))
        bad = diagnostic_page(2)[:12] + struct.pack('<8f', float('nan'), *([0] * 7))
        with self.assertRaises(ProtocolError):
            batch.add(bad)
        with self.assertRaises(ProtocolError):
            batch.report()
        with self.assertRaises(ValueError):
            diagnostic_request(9)

    def test_full_report_logging_deduplicates_and_flushes(self):
        batch = DiagnosticBatch()
        report = None
        for page in range(DIAGNOSTIC_PAGES):
            report = batch.add(diagnostic_page(page))
        with tempfile.TemporaryDirectory() as directory:
            logger = DiagnosticLogger(Path(directory))
            try:
                self.assertTrue(logger.write('freq', report))
                self.assertFalse(logger.write('freq', report))
                self.assertTrue(logger.write('dpll', report))
                rows = [json.loads(line) for line in logger.path.read_text(encoding='utf-8').splitlines()]
                self.assertEqual(len(rows), 2)
                self.assertEqual(len(rows[0]['raw_pages_hex']), 9)
            finally:
                logger.close()


if __name__ == '__main__':
    unittest.main()
