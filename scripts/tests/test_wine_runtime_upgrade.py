import hashlib
import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("wine_runtime", PROJECT / "scripts/swcli/wine_runtime.py")
RUNTIME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNTIME)


class WineUpgradeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="macsw-wine-upgrade-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.prefix = self.root / "bottle"
        (self.prefix / "drive_c").mkdir(parents=True)
        (self.prefix / "user.reg").write_text("old preferences")
        self.state = RUNTIME.state_root(self.prefix)
        self.state.mkdir()
        self.contents = self.app("old")
        self.new = self.app("new")

    def app(self, name):
        contents = self.root / (name + ".app") / "Contents"
        (contents / "Resources").mkdir(parents=True)
        values = {"WineVersion": "11.16", "MonoVersion": "11.3.0",
                  "WineTestPatchSHA256": name, "SWCLISourceCommit": name}
        self.add_modules(contents, values, RUNTIME.MODULES)
        return contents

    def add_modules(self, contents, values, modules):
        for key, relative in modules.items():
            module = contents / "Frameworks/wine" / relative.format(**values)
            module.parent.mkdir(parents=True, exist_ok=True)
            module.write_bytes(b"fixture-module")
            values[key] = hashlib.sha256(module.read_bytes()).hexdigest()
        self.manifest(contents, values)

    def manifest(self, contents, values):
        with (contents / "Resources/BuildManifest.plist").open("wb") as stream:
            plistlib.dump(values, stream)

    def baseline(self):
        with patch.object(RUNTIME, "run", side_effect=AssertionError("must not run Wine")):
            RUNTIME.baseline(self.contents, self.prefix)
        self.old = RUNTIME.read_json(self.state / "receipt.json")

    def assert_no_backups(self):
        self.assertFalse((self.state / "apps").exists())
        self.assertFalse((self.state / "backups").exists())

    def test_baseline_only_records_metadata(self):
        self.baseline()
        self.assertEqual(RUNTIME.status(self.contents, self.prefix), "ready")
        self.assertEqual(self.old["format"], 2)
        self.assertNotIn("app", self.old)
        self.assert_no_backups()

    def test_patch_change_requires_upgrade_and_blocks_launch(self):
        self.baseline()
        self.assertEqual(RUNTIME.status(self.new, self.prefix), "upgrade")
        with self.assertRaisesRegex(RuntimeError, "未启动新版 Wine"):
            RUNTIME.require_ready(self.new, self.prefix)

    def test_identity_ignores_swcli_commit(self):
        self.assertNotIn("SWCLISourceCommit", RUNTIME.identity(self.contents))

    def test_resource_alias_preserves_identity_and_hash_checks(self):
        values = RUNTIME.identity(self.new)
        alias = self.new / "Frameworks/wine"
        resource = self.new / "Resources/Wine"
        alias.rename(resource)
        alias.symlink_to("../Resources/Wine")
        RUNTIME.verify_app(self.new, values)
        (resource / RUNTIME.MODULES["WineLoaderSHA256"]).write_bytes(b"corrupt")
        with self.assertRaisesRegex(RuntimeError, "WineLoaderSHA256"):
            RUNTIME.verify_app(self.new, values)

    def test_finder_modules_replace_same_version_builtins_after_wineboot_stops(self):
        values = RUNTIME.identity(self.new)
        values["WineNativeFileManagerPatchSHA256"] = "a" * 64
        self.add_modules(self.new, values, RUNTIME.FILE_MANAGER_MODULES)
        calls = []
        def run(contents, prefix, arguments, log, **kwargs):
            calls.append((arguments, kwargs.get("server", False)))
            if "query" in arguments:
                for directory in ("system32", "syswow64"):
                    for name in ("shell32.dll", "explorer.exe"):
                        self.assertEqual((prefix / "drive_c/windows" / directory / name).read_bytes(), b"fixture-module")
        with patch.object(RUNTIME, "run", side_effect=run):
            RUNTIME.boot(self.new, self.prefix, self.state / "test.log")
        self.assertEqual(calls[:3], [([r"C:\windows\system32\wineboot.exe", "-u"], False),
                                     (["-k"], True), (["-w"], True)])
        self.assertEqual((self.prefix / "drive_c/windows/explorer.exe").read_bytes(), b"fixture-module")

    def test_finder_deployment_rejects_an_external_windows_directory(self):
        external = self.root / "external"
        external.mkdir()
        (self.prefix / "drive_c/windows").symlink_to(external)
        with self.assertRaisesRegex(RuntimeError, "指向容器外部"):
            RUNTIME.deploy_file_manager(self.new, self.prefix)
        self.assertEqual(list(external.iterdir()), [])

    def test_extensions_validate_every_module_and_reject_partial_groups(self):
        for modules, extra, label in (
            (RUNTIME.MSXML_MODULES, {"WineMSXMLSchemaPatchSHA256": "1" * 64}, "MSXML"),
            (RUNTIME.TOOLBOX_MODULES, {}, "Toolbox"),
            (RUNTIME.FILE_MANAGER_MODULES, {"WineNativeFileManagerPatchSHA256": "2" * 64}, "Finder"),
        ):
            original = RUNTIME.identity(self.new)
            values = {**original, **extra}
            self.add_modules(self.new, values, modules)
            RUNTIME.verify_app(self.new, values)
            for key, relative in modules.items():
                with self.subTest(key=key):
                    module = self.new / "Frameworks/wine" / relative.format(**values)
                    saved = module.read_bytes()
                    module.write_bytes(b"corrupt")
                    with self.assertRaisesRegex(RuntimeError, key):
                        RUNTIME.verify_app(self.new, values)
                    module.write_bytes(saved)
            for key in [*modules, *extra]:
                partial = {**original, key: "1" * 64}
                self.manifest(self.new, partial)
                with self.assertRaisesRegex(RuntimeError, label):
                    RUNTIME.identity(self.new)
                with self.assertRaisesRegex(RuntimeError, label):
                    RUNTIME.verify_app(self.new, partial)
            self.manifest(self.new, original)

    def test_baseline_cannot_bypass_version_change(self):
        self.baseline()
        with self.assertRaisesRegex(RuntimeError, "绕过"):
            RUNTIME.baseline(self.new, self.prefix)

    def test_success_uses_only_current_app_and_no_backup(self):
        self.baseline()
        with patch.object(RUNTIME, "stop") as stop, patch.object(RUNTIME, "boot") as boot:
            RUNTIME.migrate(self.new, self.prefix)
        self.assertEqual([call.args[0] for call in stop.call_args_list], [self.new, self.new])
        boot.assert_called_once_with(self.new, self.prefix, self.state / "migration.log")
        self.assertEqual(RUNTIME.status(self.new, self.prefix), "ready")
        self.assert_no_backups()
        self.assertNotIn("app", RUNTIME.read_json(self.state / "receipt.json"))

    def test_legacy_receipt_never_reads_old_archive_or_deletes_old_backups(self):
        self.baseline()
        RUNTIME.write_json(self.state / "receipt.json", {
            **self.old, "format": 1, "app": "/nonexistent/damaged/MacSW.app"})
        old_backup = self.state / "backups/keep-existing.txt"
        old_backup.parent.mkdir()
        old_backup.write_text("existing backup")
        with patch.object(RUNTIME, "stop") as stop, patch.object(RUNTIME, "boot"):
            RUNTIME.migrate(self.new, self.prefix)
        self.assertTrue(all(call.args[0] == self.new for call in stop.call_args_list))
        self.assertEqual(old_backup.read_text(), "existing backup")
        self.assertEqual(RUNTIME.read_json(self.state / "receipt.json")["format"], 2)

    def fail_boot(self):
        def boot(contents, prefix, log):
            (prefix / "user.reg").write_text("partially updated")
            raise RuntimeError("injected boot failure")
        with patch.object(RUNTIME, "stop"), patch.object(RUNTIME, "boot", side_effect=boot):
            with self.assertRaisesRegex(RuntimeError, "未备份且未自动回退"):
                RUNTIME.migrate(self.new, self.prefix)

    def test_failure_blocks_launch_without_claiming_rollback(self):
        self.baseline()
        self.fail_boot()
        self.assertEqual(RUNTIME.status(self.new, self.prefix), "recovery")
        self.assertEqual((self.prefix / "user.reg").read_text(), "partially updated")
        self.assertEqual(RUNTIME.read_json(self.state / "receipt.json"), self.old)
        self.assert_no_backups()
        with self.assertRaises(RuntimeError):
            RUNTIME.require_ready(self.new, self.prefix)

    def test_explicit_retry_finishes_without_backup(self):
        self.baseline()
        self.fail_boot()
        with patch.object(RUNTIME, "stop"), patch.object(RUNTIME, "boot"):
            RUNTIME.migrate(self.new, self.prefix, retry=True)
        self.assertEqual(RUNTIME.status(self.new, self.prefix), "ready")
        self.assertFalse((self.state / "pending.json").exists())
        self.assert_no_backups()

    def test_retry_rejects_other_version_prefix_or_path(self):
        self.baseline()
        for field, value in (("identity", {}), ("prefix_id", "other"), ("active_app", "/other.app")):
            pending = {"format": 2, "mode": "in-place", "prefix_id": self.old["prefix_id"],
                       "identity": RUNTIME.identity(self.new), "active_app": str(self.new.parent.resolve())}
            pending[field] = value
            RUNTIME.write_json(self.state / "pending.json", pending)
            with patch.object(RUNTIME, "stop") as stop:
                with self.assertRaises(RuntimeError):
                    RUNTIME.migrate(self.new, self.prefix, retry=True)
                stop.assert_not_called()
            (self.state / "pending.json").unlink()

    def test_legacy_pending_is_preserved_and_not_executed(self):
        self.baseline()
        pending = {"format": 1, "backup": "/untrusted/path"}
        RUNTIME.write_json(self.state / "pending.json", pending)
        with patch.object(RUNTIME, "stop") as stop:
            with self.assertRaisesRegex(RuntimeError, "旧版"):
                RUNTIME.migrate(self.new, self.prefix, retry=True)
            stop.assert_not_called()
        self.assertEqual(RUNTIME.read_json(self.state / "pending.json"), pending)

    def test_stop_failure_leaves_receipt_and_container_untouched(self):
        self.baseline()
        with patch.object(RUNTIME, "stop", side_effect=RuntimeError("won't stop")), patch.object(RUNTIME, "boot") as boot:
            with self.assertRaisesRegex(RuntimeError, "won't stop"):
                RUNTIME.migrate(self.new, self.prefix)
            boot.assert_not_called()
        self.assertFalse((self.state / "pending.json").exists())
        self.assertEqual(RUNTIME.read_json(self.state / "receipt.json"), self.old)

    def test_corrupt_current_app_refused_before_stop(self):
        self.baseline()
        (self.new / "Frameworks/wine" / RUNTIME.MODULES["WineLoaderSHA256"]).write_text("corrupt")
        with patch.object(RUNTIME, "stop") as stop:
            with self.assertRaisesRegex(RuntimeError, "校验失败"):
                RUNTIME.migrate(self.new, self.prefix)
            stop.assert_not_called()

    def test_shutdown_uses_current_server_without_boot(self):
        self.baseline()
        with patch.object(RUNTIME, "stop") as stop, patch.object(RUNTIME, "boot") as boot:
            RUNTIME.shutdown(self.new, self.prefix)
        self.assertEqual(stop.call_args.args[0], self.new)
        boot.assert_not_called()

    def test_boot_rebinds_regasm_and_checks_current_dependencies(self):
        with patch.object(RUNTIME, "run") as run:
            RUNTIME.boot(self.new, self.prefix, self.state / "migration.log")
        for directory in ("Framework", "Framework64"):
            target = self.prefix / f"drive_c/windows/Microsoft.NET/{directory}/v4.0.30319/regasm.exe"
            self.assertEqual(target.read_bytes(), b"fixture-module")
        self.assertEqual(run.call_args_list[0].args[2], [r"C:\windows\system32\wineboot.exe", "-u"])
        self.assertTrue(all(call.args[0] == self.new for call in run.call_args_list))

    def test_stop_runs_only_current_server_k_and_w_for_selected_prefix(self):
        responses = [subprocess.CalledProcessError(1, "no server"), subprocess.CompletedProcess([], 0)]
        with patch.object(RUNTIME.subprocess, "run", side_effect=responses) as run:
            RUNTIME.stop(self.new, self.prefix, self.state / "migration.log")
        self.assertEqual([call.args[0] for call in run.call_args_list], [
            [str(self.new / "Frameworks/wine/bin/wineserver"), "-k"],
            [str(self.new / "Frameworks/wine/bin/wineserver"), "-w"]])
        for call in run.call_args_list:
            self.assertEqual(call.kwargs["env"]["WINEPREFIX"], str(self.prefix))

    def test_stop_wait_failure_is_not_treated_as_success(self):
        responses = [subprocess.CompletedProcess([], 0), subprocess.CalledProcessError(2, "wait")]
        with patch.object(RUNTIME.subprocess, "run", side_effect=responses):
            with self.assertRaises(subprocess.CalledProcessError):
                RUNTIME.stop(self.new, self.prefix, self.state / "migration.log")

    def test_matching_identity_upgrade_is_noop(self):
        self.baseline()
        with patch.object(RUNTIME, "stop") as stop:
            RUNTIME.migrate(self.contents, self.prefix)
            stop.assert_not_called()

    def test_relocated_app_requires_rebinding(self):
        self.baseline()
        moved = self.root / "moved.app/Contents"
        shutil.copytree(self.contents, moved)
        self.assertEqual(RUNTIME.status(moved, self.prefix), "upgrade")
        with self.assertRaisesRegex(RuntimeError, "绕过"):
            RUNTIME.baseline(moved, self.prefix)

    def test_replaced_prefix_requires_baseline(self):
        self.baseline()
        (self.prefix / ".macsw-wine-prefix-id").unlink()
        self.assertEqual(RUNTIME.status(self.contents, self.prefix), "baseline")

    def test_launch_cannot_race_migration(self):
        self.baseline()
        with RUNTIME.launch_lock(self.prefix, exclusive=True):
            with patch.object(RUNTIME.subprocess, "Popen") as spawn:
                with self.assertRaisesRegex(RuntimeError, "正在执行"):
                    RUNTIME.launch(self.contents, self.prefix, ["must-not-launch"])
                spawn.assert_not_called()

    def test_unmanaged_prefix_untouched(self):
        foreign = self.root / "foreign-bottle"
        (foreign / "drive_c").mkdir(parents=True)
        self.assertEqual(RUNTIME.status(self.contents, foreign), "unmanaged")
        self.assertFalse(RUNTIME.state_root(foreign).exists())

    def test_pending_blocks_launch_and_baseline(self):
        self.baseline()
        RUNTIME.write_json(self.state / "pending.json", {"incomplete": True})
        self.assertEqual(RUNTIME.status(self.contents, self.prefix), "recovery")
        with self.assertRaises(RuntimeError):
            RUNTIME.require_ready(self.contents, self.prefix)
        with self.assertRaises(RuntimeError):
            RUNTIME.baseline(self.contents, self.prefix)

    def test_symlink_prefix_rejected(self):
        link = self.root / "link"
        link.symlink_to(self.prefix)
        with self.assertRaisesRegex(RuntimeError, "不安全"):
            RUNTIME.baseline(self.contents, link)


if __name__ == "__main__":
    unittest.main()
