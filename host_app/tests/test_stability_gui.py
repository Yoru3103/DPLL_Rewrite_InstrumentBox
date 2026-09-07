import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
import tempfile
import unittest
from unittest.mock import patch

try:
    from PyQt6.QtWidgets import QApplication, QMessageBox
    from dpll_host.stability_page import StabilityPage
    from dpll_host.app import MainWindow
except ImportError:
    QApplication = None

from test_stability import FakeBoard


@unittest.skipIf(QApplication is None, "PyQt6 is not installed in this interpreter")
class StabilityGuiTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.page = StabilityPage()
        self.page.output.setText(self.tmp.name)
        self.page.profiles.setPlainText('[{"name":"original","pid":null}]')
        self.page.samples.setValue(2)
        self.page.repeats.setValue(1)
        self.page.settle.setValue(0)
        self.requests = []
        self.page.request.connect(lambda tag, cmd, payload: self.requests.append((tag, cmd, payload)))
        self.board = FakeBoard()

    def tearDown(self):
        if self.page.active:
            self.page.disconnected()
        self.page.deleteLater()
        self.tmp.cleanup()

    def start(self):
        with patch.object(QMessageBox, "question", return_value=QMessageBox.StandardButton.Yes):
            self.page.start()

    def drain(self):
        for _ in range(1000):
            if not self.page.active:
                return
            if self.requests:
                tag, cmd, payload = self.requests.pop(0)
                self.page.response(tag, self.board.response(cmd, payload))
            else:
                self.page.timer.stop()
                self.page._drive()
        self.fail("GUI sequence did not finish")

    def test_complete(self):
        self.start()
        self.assertFalse(self.page.start_button.isEnabled())
        self.drain()
        self.assertTrue(self.page.run.restored)
        self.assertIn("参考排序", self.page.results.toPlainText())
        self.assertTrue(self.page.start_button.isEnabled())

    def test_stop_pending_request(self):
        self.start()
        while not self.page.run.changed:
            tag, cmd, payload = self.requests.pop(0)
            self.page.response(tag, self.board.response(cmd, payload))
        self.page.stop()
        self.drain()
        self.assertTrue(self.page.run.restored)
        self.assertEqual(self.board.triggers, 0)
        self.assertNotIn("参考排序", self.page.results.toPlainText())

    def test_disconnect(self):
        self.start()
        self.page.disconnected()
        self.assertFalse(self.page.active)
        self.assertIn("串口断开", self.page.status.text())

    def test_main_window_tab(self):
        window = MainWindow()
        names = [window.tabs.tabText(i) for i in range(window.tabs.count())]
        self.assertIn("固定 PID 稳定度", names)
        window.close()


if __name__ == "__main__":
    unittest.main()
