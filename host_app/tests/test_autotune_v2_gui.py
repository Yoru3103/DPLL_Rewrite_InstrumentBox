import os
os.environ.setdefault('QT_QPA_PLATFORM', 'offscreen')
import tempfile
import unittest
from unittest.mock import Mock

try:
    from PyQt6.QtWidgets import QApplication
    from dpll_host.app import AutotunePage, MainWindow
except ImportError:
    QApplication = None

from dpll_host.protocol import LoopTarget, ProtocolError
from dpll_host.autotune_diagnostics import AutotuneConfig, DIAGNOSTIC_PAGES
from dpll_host.validation import ValidationCase, ValidationLogger
from pathlib import Path
from test_autotune_v2 import status_payload, config_payload, diagnostic_page


@unittest.skipIf(QApplication is None, 'PyQt6 is not installed')
class AutotuneV2GuiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.page = AutotunePage()
        self.page.poll_timer.stop()
        self.diag = self.page.diagnostics
        self.diag.timer.stop()
        self.page.output.setText(self.tmp.name)
        self.requests = []
        self.page.request.connect(lambda tag, command, payload: self.requests.append((tag, command, payload)))
        self.diag.set_connected(True)

    def tearDown(self):
        self.diag.set_connected(False)
        self.page.deleteLater()
        self.tmp.cleanup()

    def ready(self, version=2):
        self.page.handle_response('autotune:freq:poll', status_payload(version))

    def deliver(self, payload):
        tag, _, _ = self.requests.pop(0)
        self.page.handle_response(tag, payload)
        return tag

    def test_legacy_has_no_new_commands_and_only_supported_policy(self):
        self.ready(1)
        self.diag.tick()
        self.assertEqual(self.requests, [])
        self.assertFalse(self.diag.panels[LoopTarget.FREQ].read_button.isEnabled())
        self.assertEqual(self.page.freq.policy.count(), 1)
        self.diag.read_config(LoopTarget.FREQ)
        self.assertEqual(self.requests, [])

    def test_configuration_write_requires_exact_readback(self):
        self.ready()
        self.diag.write_config(LoopTarget.FREQ)
        self.assertEqual(self.requests[0][2][0], 7)
        self.deliver(status_payload(action=7))
        self.assertEqual(self.requests[0][2], b'\x06')
        self.deliver(config_payload())
        self.assertIn('完全一致', self.diag.panels[LoopTarget.FREQ].config_status.text())
        self.diag.write_config(LoopTarget.FREQ)
        self.deliver(status_payload(action=7))
        with self.assertRaises(ProtocolError):
            self.deliver(config_payload(AutotuneConfig(repeats=4)))

    def test_invalid_configuration_does_not_send(self):
        self.ready()
        fields = self.diag.panels[LoopTarget.FREQ].fields
        fields['window_ms'].setValue(2000)
        fields['repeats'].setValue(5)
        self.diag.write_config(LoopTarget.FREQ)
        self.assertEqual(self.requests, [])
        self.assertIn('6000', self.diag.panels[LoopTarget.FREQ].config_status.text())

    def test_pages_are_sequential_and_complete_reports_logged_once(self):
        self.ready()
        self.diag.config_seen.add(LoopTarget.FREQ)
        self.diag.tick()
        for page in range(DIAGNOSTIC_PAGES):
            self.assertEqual(len(self.requests), 1)
            self.assertEqual(self.requests[0][2], bytes((5, page)))
            self.deliver(diagnostic_page(page))
        self.assertIsNone(self.diag.batch)
        self.assertIn('频率 RMS', self.diag.panels[LoopTarget.FREQ].report.toPlainText())
        self.assertEqual(len(self.diag.logger.path.read_text(encoding='utf-8').splitlines()), 1)
        self.diag.tick()
        self.deliver(diagnostic_page(0))
        self.assertEqual(self.requests, [])
        self.assertEqual(len(self.diag.logger.path.read_text(encoding='utf-8').splitlines()), 1)

    def test_suspension_and_disconnect_drop_inflight_pages(self):
        self.ready()
        self.diag.config_seen.add(LoopTarget.FREQ)
        self.diag.tick()
        old_tag, _, _ = self.requests.pop(0)
        self.diag.set_suspended(True)
        self.page.handle_response(old_tag, diagnostic_page(0))
        self.diag.tick()
        self.assertEqual(self.requests, [])
        self.assertIsNone(self.diag.batch)
        self.diag.set_suspended(False)
        self.diag.tick()
        old_tag, _, _ = self.requests.pop(0)
        self.diag.set_connected(False)
        self.page.handle_response(old_tag, diagnostic_page(0))
        self.assertEqual(self.requests, [])
        self.assertIsNone(self.diag.batch)
        self.assertEqual(self.diag.versions, {})

    def test_busy_blocks_configuration_mutation(self):
        self.ready()
        self.page.handle_response('autotune:dpll:poll', status_payload(busy=True))
        self.assertFalse(self.diag.panels[LoopTarget.FREQ].write_button.isEnabled())
        self.diag.write_config(LoopTarget.FREQ)
        self.assertEqual(self.requests, [])

    def test_validation_rejected_start_does_not_reuse_old_done(self):
        window = MainWindow()
        window.validation_case = ValidationCase('test', LoopTarget.FREQ)
        window.validation_phase = 'wait_start'
        window._finish_validation_trial = Mock()
        window._validation_response('validation:start', status_payload(action=1, result=10))
        window._finish_validation_trial.assert_called_once()
        self.assertEqual(window._finish_validation_trial.call_args.args[0], 'FAILED')
        window.close()

    def test_validation_stop_waits_for_device_and_blocks_other_traffic(self):
        window = MainWindow()
        window.autotune.poll_timer.stop()
        window.autotune.diagnostics.timer.stop()
        worker = Mock()
        worker.isRunning.return_value = True
        window.worker = worker
        window.validation_logger = ValidationLogger(Path(self.tmp.name))
        window.validation_case = ValidationCase('test', LoopTarget.FREQ)
        window.validation_phase = 'poll'
        window.validation_queue.append((window.validation_case, 2))
        window.stop_validation()
        self.assertEqual(window.validation_phase, 'cancel_wait')
        self.assertIsNotNone(window.validation_logger)
        self.assertFalse(window.validation_queue)
        sent = worker.submit.call_count
        window.send_request('autotune:freq:diag_0:1', 0x97, b'\x05\x00')
        self.assertEqual(worker.submit.call_count, sent)
        window._validation_response('validation:cancel', status_payload(action=2, busy=True))
        self.assertEqual(window.validation_phase, 'cancel_wait')
        window._validation_response('validation:query', status_payload(result=9))
        self.assertIsNone(window.validation_logger)
        window.worker = None
        window.close()


if __name__ == '__main__':
    unittest.main()
