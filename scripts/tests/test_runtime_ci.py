"""Offline adapter checks; CAD semantics are owned exclusively by SWCLI."""

import importlib.util
import base64
import json
import os
import plistlib
import shutil
from pathlib import Path
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("macsw_runtime_ci", PROJECT / "scripts/ci/verify-runtime.py")
ci = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ci)
redact_spec = importlib.util.spec_from_file_location("macsw_redact", PROJECT / "scripts/ci/redact-evidence.py")
privacy = importlib.util.module_from_spec(redact_spec)
redact_spec.loader.exec_module(privacy)
mount_spec = importlib.util.spec_from_file_location("macsw_mount", PROJECT / "scripts/ci/mount-install.py")
media = importlib.util.module_from_spec(mount_spec)
mount_spec.loader.exec_module(media)
cache_spec = importlib.util.spec_from_file_location("macsw_base_cache", PROJECT / "scripts/ci/bottle-cache.py")
base_cache = importlib.util.module_from_spec(cache_spec)
cache_spec.loader.exec_module(base_cache)


class RuntimeAdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.environment = patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_TEMP": str(self.directory),
                                                  "SW_SERIAL_SOLIDWORKS": "private", "RCLONE_CONFIG_B64": "private"})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.root = self.directory / "MacSW-runtime"
        self.app = self.root / "MacSW.app"
        self.app.mkdir(parents=True)
        (self.root / "app-support/bottle/dosdevices").mkdir(parents=True)

    def gate(self):
        return ci.RuntimeGate(self.app, self.root / "evidence")

    def test_non_ci_and_user_app_are_rejected(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}):
            with self.assertRaisesRegex(RuntimeError, "runner required"):
                self.gate()
        with self.assertRaisesRegex(RuntimeError, "isolated CI"):
            ci.RuntimeGate(Path("/Applications/MacSW.app"), self.root / "evidence")

    def test_real_mapping_and_secrets_not_forwarded(self):
        gate = self.gate()
        self.assertNotIn("SW_SERIAL_SOLIDWORKS", gate.env)
        self.assertNotIn("RCLONE_CONFIG_B64", gate.env)
        self.assertEqual((gate.prefix / "dosdevices/m:").resolve(), self.root)
        self.assertTrue(Path(gate.env["TMPDIR"]).is_relative_to(gate.prefix / "drive_c"))
        with patch.object(gate, "command", return_value="Q:\\real\\models\n") as command:
            self.assertEqual(gate.windows_path(self.root / "models"), "Q:\\real\\models")
            command.assert_called_once_with([gate.path_helper, self.root / "models"])

    def test_shared_modeling_then_driving_without_intermediate_restart(self):
        gate = self.gate()
        scripts = [Path("verify-modeling.py"), Path("verify-driving-dimensions.py")]
        events = []
        host = {"process_id": 42}
        def command(args, **kwargs):
            events.append(args[1].name)
            self.assertIn("--cli-command", args)
            self.assertIn("--host-output-dir", args)
            self.assertIn("--endpoint", args)
            output = args[args.index("--output-dir") + 1]
            self.assertTrue(output.is_relative_to(gate.prefix / "drive_c"))
            if args[1].name == "verify-driving-dimensions.py":
                self.assertIn("--after-modeling", args)
                self.assertEqual(args[args.index("--after-modeling") + 1],
                                 output.parent / "modeling/modeling.json")
            else:
                self.assertNotIn("--after-modeling", args)
        with patch.object(ci, "shared_gates", return_value=scripts), \
                patch.object(gate, "start", side_effect=lambda mode: events.append("start:" + mode) or host), \
                patch.object(gate, "same_host", side_effect=lambda expected: self.assertEqual(expected, host)), \
                patch.object(gate, "command", side_effect=command), \
                patch.object(gate, "windows_path", return_value="Q:\\models"), \
                patch.object(gate, "collect_evidence"), \
                patch.object(gate, "stop", side_effect=lambda: events.append("stop")):
            gate.run()
        self.assertEqual(events, ["start:visible", "verify-modeling.py", "verify-driving-dimensions.py", "stop",
                                  "start:hidden", "verify-modeling.py", "verify-driving-dimensions.py", "stop"])
        self.assertTrue(gate.record["completed"])

    def test_host_change_aborts_before_next_gate(self):
        gate = self.gate()
        with patch.object(gate, "host", return_value={"process_id": 43}):
            with self.assertRaisesRegex(RuntimeError, "changed between shared gates"):
                gate.same_host({"process_id": 42})

    def test_missing_shared_gate_is_not_silently_skipped(self):
        with patch.object(ci, "PROJECT", self.directory):
            with self.assertRaisesRegex(RuntimeError, "verify-modeling.py"):
                ci.shared_gates()

    def test_remote_mount_is_limited_to_iso_parent(self):
        self.assertEqual(media.media_location("Share/Software/SW/media.iso"),
                         ("gdrive:Share/Software/SW", "media.iso"))
        for invalid in ("/media.iso", "../media.iso", "gdrive:media.iso", "media.exe"):
            with self.assertRaisesRegex(RuntimeError, "relative ISO"):
                media.media_location(invalid)

    def test_read_only_nfs_mount_provides_local_hdiutil_locks(self):
        command = media.mount_command("private.conf", "gdrive:media", "mount", "files.txt", "cache")
        self.assertIn("nfsmount", command)
        self.assertIn("--read-only", command)
        self.assertEqual(command[command.index("--option") + 1], "ro,locallocks,intr")
        self.assertEqual(command[command.index("--files-from-raw") + 1], "files.txt")

    def test_prerequisite_evidence_contains_codes_not_private_log_text(self):
        logs = self.root / "app-support/logs"
        logs.mkdir()
        (logs / "vcredist-x64.log").write_bytes(
            "Error 0x80070656: private serial and credentials\nApply complete, result: 0x80070656".encode("utf-16"))
        (logs / "vcredist-private.log").symlink_to(logs / "vcredist-x64.log")
        media.prerequisite_diagnostics(self.root)
        output = (self.root / "evidence/prerequisite-diagnostics.json").read_text()
        record = json.loads(output)
        self.assertTrue(record["vc_log_created"])
        self.assertEqual(len(record["logs"]), 1)
        self.assertEqual(record["logs"]["0"]["codes"], ["0x80070656"])
        self.assertNotIn("private", output)
        self.assertNotIn("serial", output)
        self.assertNotIn("credentials", output)

    def test_media_cleanup_detaches_only_this_ci_image(self):
        mountpoint = self.root / "media-mount"
        mountpoint.mkdir()
        images = {"images": [
            {"image-path": str(mountpoint / "media.iso"),
             "system-entities": [{"dev-entry": "/dev/disk7"}, {"dev-entry": "/dev/disk7s1"}]},
            {"image-path": "/Volumes/unrelated/media.iso", "system-entities": [{"dev-entry": "/dev/disk8"}]}]}
        with patch.object(media, "mounted", return_value=False), \
                patch.object(media.subprocess, "run", return_value=SimpleNamespace(stdout=plistlib.dumps(images))) as run:
            media.stop_mount(self.root)
            calls = [call.args[0] for call in run.call_args_list]
        self.assertIn(["/usr/bin/hdiutil", "detach", "/dev/disk7", "-force"], calls)
        self.assertNotIn(["/usr/bin/hdiutil", "detach", "/dev/disk8", "-force"], calls)
        self.assertFalse(mountpoint.exists())

    def test_media_cleanup_never_recursively_deletes_live_mount(self):
        mountpoint = self.root / "media-mount"
        mountpoint.mkdir()
        sentinel = mountpoint / "remote-sentinel"
        sentinel.write_text("must survive")
        with patch.object(media, "mounted", return_value=True), \
                patch.object(media.subprocess, "run", return_value=SimpleNamespace(stdout=plistlib.dumps({}))), \
                patch.object(media.os, "kill"):
            # A still-mounted/nonempty directory must never be recursively erased.
            media.stop_mount(self.root)
        self.assertTrue(sentinel.exists())

    def test_cleanup_removes_only_private_products(self):
        for name in ("private", "app-support", "evidence"):
            (self.root / name).mkdir(exist_ok=True)
            (self.root / name / "sentinel").write_text("fixture")
        unrelated = self.directory / "unrelated"
        unrelated.mkdir()
        with self.assertRaisesRegex(RuntimeError, "outside"):
            ci.remove_private_inputs(unrelated)
        ci.remove_private_inputs(self.root)
        self.assertTrue((self.root / "evidence/sentinel").exists())
        self.assertTrue(unrelated.exists())
        for name in ("private", "app-support", "MacSW.app"):
            self.assertFalse((self.root / name).exists())

    def test_timeout_output_can_be_bytes_or_text(self):
        self.assertEqual(ci.text_output(b"partial"), "partial")
        self.assertEqual(ci.text_output("partial"), "partial")
        self.assertEqual(ci.text_output(None), "")

    def test_failed_process_cleanup_still_erases_private_inputs(self):
        helper = self.app / "Contents/MacOS/MacSWCI"
        helper.parent.mkdir(parents=True)
        helper.write_text("fixture")
        with patch.object(ci.subprocess, "run", return_value=SimpleNamespace(returncode=1)):
            with self.assertRaisesRegex(RuntimeError, "cleanup exited"):
                ci.cleanup_runtime(self.root)
        self.assertFalse(self.app.exists())
        self.assertFalse((self.root / "app-support").exists())

    def test_publication_redacts_formatted_serial_and_drive_tokens(self):
        serial = "ABCD-EFGH-IJKL-MNOP-QRST-UVWX"
        configuration = '[gdrive]\ntype = drive\ntoken = {"access_token":"private-access-token","refresh_token":"private-refresh-token"}\n'
        values = privacy.sensitive_values({"SW_SERIAL_SOLIDWORKS": serial,
                                          "RCLONE_CONFIG_B64": base64.b64encode(configuration.encode()).decode()})
        for value in (serial, serial.replace("-", ""), serial.replace("-", " "),
                      "private-access-token", "private-refresh-token"):
            self.assertEqual(privacy.redact(value, values), "[REDACTED]")
        self.assertEqual(privacy.redact("SIMULATIONSERIALNUMBER=unexpected", values),
                         "SIMULATIONSERIALNUMBER=[REDACTED]")

    def official_base(self):
        serial = "ABCD-EFGH-IJKL-MNOP-QRST-UVWX"
        os.environ["SW_SERIAL_SOLIDWORKS"] = serial
        evidence = self.root / "evidence"
        evidence.mkdir()
        (evidence / "setup.json").write_text(json.dumps({"completed": True, "fixture_ready": False}))
        bottle = self.root / "app-support/bottle"
        program = bottle / "drive_c/Program Files/SOLIDWORKS/SLDWORKS.exe"
        program.parent.mkdir(parents=True)
        program.write_bytes(b"official test binary")
        (bottle / "dosdevices/c:").symlink_to("../drive_c")
        (bottle / "dosdevices/z:").symlink_to("/")
        (bottle / "system.reg").write_text('"Serial Number"="' + serial.replace("-", "") + '"\n')
        (bottle / "install.log").write_text(serial)
        temporary = bottle / "drive_c/windows/temp"
        temporary.mkdir(parents=True)
        (temporary / "private-msi.tmp").write_text(serial)
        return bottle, serial

    def test_complete_base_cache_strips_serials_logs_and_per_run_mappings(self):
        bottle, serial = self.official_base()
        base_cache.export_snapshot("context")
        snapshot = self.root / "base-cache/bottle"
        self.assertNotIn(serial.replace("-", ""), (snapshot / "system.reg").read_text())
        self.assertIn(serial.replace("-", ""), (bottle / "system.reg").read_text())
        self.assertFalse((snapshot / "install.log").exists())
        self.assertFalse((snapshot / "drive_c/windows/temp").exists())
        self.assertTrue((snapshot / "dosdevices/c:").is_symlink())
        self.assertFalse((snapshot / "dosdevices/z:").is_symlink())
        shutil.rmtree(bottle)
        base_cache.restore_snapshot("context")
        self.assertTrue((bottle / "drive_c/Program Files/SOLIDWORKS/SLDWORKS.exe").is_file())
        self.assertEqual(json.loads((self.root / "evidence/cache.json").read_text())["source"],
                         "installed-base-cache")

    def test_private_fixtures_and_binary_secrets_block_cache_publication(self):
        bottle, serial = self.official_base()
        (self.root / "evidence/setup.json").write_text(json.dumps({"completed": True, "fixture_ready": True}))
        with self.assertRaisesRegex(RuntimeError, "before fixture injection"):
            base_cache.export_snapshot("context")
        (self.root / "evidence/setup.json").write_text(json.dumps({"completed": True, "fixture_ready": False}))
        (bottle / "secret.bin").write_bytes(serial.replace("-", "").encode("utf-16le"))
        with self.assertRaisesRegex(RuntimeError, "Sensitive data"):
            base_cache.export_snapshot("context")
        self.assertFalse((self.root / "base-cache").exists())

    def test_base_cache_integrity_and_context_are_checked_before_restore(self):
        bottle, serial = self.official_base()
        base_cache.export_snapshot("context")
        shutil.rmtree(bottle)
        with self.assertRaisesRegex(RuntimeError, "context mismatch"):
            base_cache.restore_snapshot("different-context")
        snapshot = self.root / "base-cache/bottle/system.reg"
        snapshot.write_text("tampered")
        with self.assertRaisesRegex(RuntimeError, "integrity"):
            base_cache.restore_snapshot("context")
        self.assertFalse(bottle.exists())

    def test_hive_hex_multistring_serial_is_masked_without_changing_type(self):
        bottle, serial = self.official_base()
        text = "prefix\0" + serial.replace("-", "").lower() + "\0suffix\0\0"
        payload = ",".join(format(byte, "02x") for byte in text.encode("utf-16le"))
        hive = bottle / "user.reg"
        # Include a continuation exactly as Wine/.reg multi-string text may use.
        payload = payload[:90] + "\\\n  " + payload[90:]
        hive.write_text('"Serials"=hex(7):' + payload + "\n")
        base_cache.export_snapshot("context")
        cached = (self.root / "base-cache/bottle/user.reg").read_text().strip()
        self.assertTrue(cached.startswith('"Serials"=hex(7):'))
        decoded = bytes.fromhex(cached.split(":", 1)[1].replace(",", " ")).decode("utf-16le")
        self.assertEqual(decoded, "prefix\0" + "0" * 24 + "\0suffix\0\0")


if __name__ == "__main__":
    unittest.main()
