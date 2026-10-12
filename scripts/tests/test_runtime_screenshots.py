import hashlib
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("sw_window_capture", ROOT / "scripts/ci/capture-sw-window.py")
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)
privacy_spec = importlib.util.spec_from_file_location("capture_privacy", ROOT / "scripts/ci/redact-evidence.py")
privacy = importlib.util.module_from_spec(privacy_spec)
privacy_spec.loader.exec_module(privacy)


class RuntimeScreenshotTests(unittest.TestCase):
    def png(self):
        return b"\x89PNG\r\n\x1a\n" + b"\0\0\0\rIHDR" + struct.pack(">II", 600, 400)

    def test_owner_and_layer_filter_never_selects_other_app_or_desktop(self):
        windows = [{"pid": pid, "id": i + 1, "layer": layer, "width": 1000, "height": 600}
                   for i, (pid, layer) in enumerate(((99, 0), (42, 25), (42, 0), (42, 0)))]
        self.assertEqual(capture.choose_window(windows, 42)["id"], 3)
        self.assertIsNone(capture.choose_window(windows, 1))

    def test_window_capture_uses_explicit_id_and_hashes_png(self):
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "sw.png"
            def run(args, **kwargs):
                self.assertEqual(args[:6], ["/usr/sbin/screencapture", "-x", "-o", "-l", "123", str(image)])
                image.write_bytes(self.png())
                return SimpleNamespace(returncode=0)
            with patch.object(capture, "visible_windows", return_value=[
                    {"pid": 42, "id": 123, "layer": 0, "width": 600, "height": 400}]), \
                    patch.object(capture.subprocess, "run", side_effect=run):
                record = capture.capture(42, image)
            self.assertTrue(record["success"])
            self.assertEqual(record["sha256"], hashlib.sha256(self.png()).hexdigest())
            self.assertEqual((record["width"], record["height"]), (600, 400))
            self.assertEqual(json.loads(image.with_suffix(".json").read_text()), record)

    def test_capture_failure_removes_only_own_partial_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "sw.png"
            def fail(*args, **kwargs):
                image.write_bytes(b"partial")
                return SimpleNamespace(returncode=1)
            with patch.object(capture, "visible_windows", return_value=[
                    {"pid": 42, "id": 123, "layer": 0, "width": 600, "height": 400}]), \
                    patch.object(capture.subprocess, "run", side_effect=fail):
                self.assertFalse(capture.capture(42, image)["success"])
            self.assertFalse(image.exists())
            image.write_bytes(b"existing")
            with self.assertRaises(ValueError):
                capture.capture(42, image)
            self.assertEqual(image.read_bytes(), b"existing")

    def test_desktop_requires_hosted_ci_and_works_after_host_disappeared(self):
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "desktop.png"
            with patch.dict(capture.os.environ, {}, clear=True), self.assertRaises(ValueError):
                capture.capture(0, image, "desktop")
            with patch.dict(capture.os.environ, GITHUB_ACTIONS="true", RUNNER_ENVIRONMENT="self-hosted"), \
                    self.assertRaises(ValueError):
                capture.capture(0, image, "desktop")
            def run(args, **kwargs):
                self.assertEqual(args, ["/usr/sbin/screencapture", "-x", "-o", "-D", "1", str(image)])
                image.write_bytes(self.png())
                return SimpleNamespace(returncode=0)
            with patch.dict(capture.os.environ, GITHUB_ACTIONS="true", RUNNER_ENVIRONMENT="github-hosted"), \
                    patch.object(capture, "visible_windows") as windows, \
                    patch.object(capture.subprocess, "run", side_effect=run):
                receipt = capture.capture(0, image, "desktop")
            windows.assert_not_called()
            self.assertEqual(receipt["source"], "github-hosted-desktop")
            self.assertEqual(receipt["display_id"], 1)
            self.assertTrue(receipt["success"])

    def test_capture_timeout_removes_partial_png(self):
        with tempfile.TemporaryDirectory() as temporary:
            image = Path(temporary) / "timeout.png"
            def timeout(*args, **kwargs):
                image.write_bytes(b"partial")
                raise subprocess.TimeoutExpired("screencapture", 15)
            with patch.dict(capture.os.environ, GITHUB_ACTIONS="true", RUNNER_ENVIRONMENT="github-hosted"), \
                    patch.object(capture.subprocess, "run", side_effect=timeout), \
                    self.assertRaises(subprocess.TimeoutExpired):
                capture.capture(0, image, "desktop")
            self.assertFalse(image.exists())

    def test_publication_requires_owned_stage_and_matching_receipt(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "MacSW-runtime/evidence/screenshots"
            directory.mkdir(parents=True)
            image = directory / "visible-modeling-start.png"
            image.write_bytes(self.png())
            receipt = {"source": "owned-sw-window", "success": True, "owned_by_daemon": True,
                       "shared_interactive": False, "phase": "visible.modeling", "file": image.name,
                       "unix_pid": 42, "window_id": 123, "host_windows_pid": 512,
                       "width": 600, "height": 400,
                       "size_bytes": len(self.png()), "sha256": hashlib.sha256(self.png()).hexdigest()}
            with patch.dict(privacy.os.environ, GITHUB_ACTIONS="true", RUNNER_TEMP=temporary,
                            RCLONE_CONFIG_B64=""):
                for changes in ({}, {"phase": "visible.startup"}, {"source": "desktop"},
                                {"owned_by_daemon": False}, {"sha256": "wrong"},
                                {"unix_pid": True}, {"file": "other.png"}, {"width": 300}):
                    with self.subTest(changes=changes):
                        image.with_suffix(".json").write_text(json.dumps({**receipt, **changes}))
                        if changes:
                            with self.assertRaises(RuntimeError):
                                privacy.main()
                        else:
                            privacy.main()

    def test_desktop_publication_receipt_requires_hosted_origin(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "MacSW-runtime/evidence/screenshots"
            directory.mkdir(parents=True)
            image = directory / "visible-driving-failure.png"
            image.write_bytes(self.png())
            receipt = {"source": "github-hosted-desktop", "success": True, "owned_by_daemon": True,
                       "shared_interactive": False, "runner_environment": "github-hosted", "display_id": 1,
                       "phase": "visible.test-sets", "test_set": "exports", "file": image.name, "host_windows_pid": 512,
                       "width": 600, "height": 400,
                       "size_bytes": len(self.png()), "sha256": hashlib.sha256(self.png()).hexdigest()}
            with patch.dict(privacy.os.environ, GITHUB_ACTIONS="true", RUNNER_TEMP=temporary,
                            RCLONE_CONFIG_B64=""):
                for changes in ({}, {"runner_environment": "self-hosted"}, {"display_id": True},
                                {"phase": "visible.prepare"}, {"host_windows_pid": False}):
                    with self.subTest(changes=changes):
                        image.with_suffix(".json").write_text(json.dumps({**receipt, **changes}))
                        if changes:
                            with self.assertRaises(RuntimeError):
                                privacy.main()
                        else:
                            privacy.main()


if __name__ == "__main__":
    unittest.main()
