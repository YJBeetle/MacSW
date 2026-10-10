import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("wine_runtime", PROJECT / "scripts/swcli/wine_runtime.py")
RUNTIME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNTIME)


class WineUpgradeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="macsw-wine-upgrade-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.prefix = self.root / "bottle"
        (self.prefix / "drive_c").mkdir(parents=True)
        (self.prefix / "user.reg").write_text("old fonts and preferences")
        self.contents = self.app("old", "patch-one")
        self.new = self.app("new", "patch-two")
        self.clone = patch.object(RUNTIME, "clone", side_effect=lambda source, target: shutil.copytree(source, target, symlinks=True))
        self.clone.start()
        self.addCleanup(self.clone.stop)
        RUNTIME.state_root(self.prefix).mkdir()

    def app(self, name, patch_identity):
        contents = self.root / (name + ".app") / "Contents"
        (contents / "Resources").mkdir(parents=True)
        values = {"WineVersion": "11.16", "MonoVersion": "11.3.0", "WineTestPatchSHA256": patch_identity,
                  "SWCLISourceCommit": name}
        for key, relative in RUNTIME.MODULES.items():
            module = contents / "Frameworks/wine" / relative.format(**values)
            module.parent.mkdir(parents=True, exist_ok=True)
            module.write_bytes(b"fixture-module")
            values[key] = hashlib.sha256(module.read_bytes()).hexdigest()
        with (contents / "Resources/BuildManifest.plist").open("wb") as stream:
            plistlib.dump(values, stream)
        return contents

    def baseline(self):
        with patch.object(RUNTIME, "run", side_effect=AssertionError("must not run Wine")):
            RUNTIME.baseline(self.contents, self.prefix)
        self.old = RUNTIME.read_json(RUNTIME.state_root(self.prefix) / "receipt.json")
        self.archived_old = Path(self.old["app"]) / "Contents"

    def test_baseline_archives_without_wineboot(self):
        self.baseline()
        self.assertEqual(RUNTIME.status(self.contents, self.prefix), "ready")
        self.assertTrue(Path(self.old["app"]).is_dir())
        self.assertEqual((self.prefix / "user.reg").read_text(), "old fonts and preferences")

    def test_same_wine_version_but_changed_patch_needs_upgrade(self):
        self.baseline()
        self.assertEqual(RUNTIME.status(self.new, self.prefix), "upgrade")
        with self.assertRaisesRegex(RuntimeError, "未启动新版 Wine"):
            RUNTIME.require_ready(self.new, self.prefix)

    def test_identity_ignores_swcli_commit(self):
        self.assertNotIn("SWCLISourceCommit", RUNTIME.identity(self.contents))

    def msxml_modules(self, contents):
        values = RUNTIME.identity(contents)
        for key, relative in RUNTIME.MSXML_MODULES.items():
            module = contents / 'Frameworks/wine' / relative
            module.parent.mkdir(parents=True, exist_ok=True)
            module.write_bytes(b'msxml-schema-namespace-module')
            values[key] = hashlib.sha256(module.read_bytes()).hexdigest()
        values['WineMSXMLSchemaPatchSHA256'] = '1' * 64
        with (contents / 'Resources/BuildManifest.plist').open('wb') as stream:
            plistlib.dump(values, stream)
        return values

    def test_msxml_identity_without_mono_overlay_requires_upgrade(self):
        self.baseline()
        values = self.msxml_modules(self.new)
        RUNTIME.verify_app(self.new, values)
        self.assertEqual(RUNTIME.status(self.new, self.prefix), 'upgrade')

    def test_corrupt_msxml_rejected_before_upgrade(self):
        values = self.msxml_modules(self.new)
        module = self.new / 'Frameworks/wine/lib/wine/x86_64-windows/msxml3.dll'
        module.write_bytes(b'corrupt')
        with self.assertRaisesRegex(RuntimeError, 'WineMSXML3ModuleSHA256'):
            RUNTIME.verify_app(self.new, values)

    def test_partial_msxml_manifest_rejected(self):
        baseline = RUNTIME.identity(self.new)
        for key in RUNTIME.MSXML_IDENTITY_KEYS:
            with self.subTest(key=key):
                partial = {**baseline, key: '1' * 64}
                with (self.new / 'Resources/BuildManifest.plist').open('wb') as stream:
                    plistlib.dump(partial, stream)
                with self.assertRaisesRegex(RuntimeError, 'MSXML'):
                    RUNTIME.identity(self.new)
                with self.assertRaisesRegex(RuntimeError, 'MSXML'):
                    RUNTIME.verify_app(self.new, partial)

    def toolbox_modules(self, contents):
        values = self.msxml_modules(contents)
        for key, relative in RUNTIME.TOOLBOX_MODULES.items():
            module = contents / 'Frameworks/wine' / relative.format(**values)
            module.parent.mkdir(parents=True, exist_ok=True)
            module.write_bytes(b'new-toolbox-module')
            values[key] = hashlib.sha256(module.read_bytes()).hexdigest()
        with (contents / 'Resources/BuildManifest.plist').open('wb') as stream:
            plistlib.dump(values, stream)
        return values

    def test_complete_toolbox_extension_verified_and_requires_upgrade(self):
        self.baseline()
        values = self.toolbox_modules(self.new)
        RUNTIME.verify_app(self.new, values)
        self.assertEqual(RUNTIME.status(self.new, self.prefix), 'upgrade')

    def test_corrupt_toolbox_module_rejected_before_upgrade(self):
        values = self.toolbox_modules(self.new)
        for key, relative in RUNTIME.TOOLBOX_MODULES.items():
            module = self.new / 'Frameworks/wine' / relative.format(**values)
            original = module.read_bytes()
            module.write_bytes(b'corrupt')
            with self.assertRaisesRegex(RuntimeError, key):
                RUNTIME.verify_app(self.new, values)
            module.write_bytes(original)

    def test_partial_toolbox_extension_is_not_a_legacy_manifest(self):
        values = RUNTIME.identity(self.new)
        values['MonoCCWModuleSHA256'] = '1'*64
        with (self.new / 'Resources/BuildManifest.plist').open('wb') as stream:
            plistlib.dump(values, stream)
        with self.assertRaisesRegex(RuntimeError, 'Toolbox'):
            RUNTIME.identity(self.new)
        with self.assertRaisesRegex(RuntimeError, 'Toolbox'):
            RUNTIME.verify_app(self.new, values)

    def test_changed_identity_cannot_bypass_by_baseline(self):
        self.baseline()
        with self.assertRaisesRegex(RuntimeError, "绕过"):
            RUNTIME.baseline(self.new, self.prefix)

    def test_success_keeps_original_full_bottle_and_old_app(self):
        self.baseline()
        with patch.object(RUNTIME, "stop"), patch.object(RUNTIME, "boot"):
            RUNTIME.migrate(self.new, self.prefix)
        self.assertEqual(RUNTIME.status(self.new, self.prefix), "ready")
        backups = list(RUNTIME.state_root(self.prefix).glob("backups/*/bottle/user.reg"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), "old fonts and preferences")
        self.assertTrue(Path(self.old["app"]).exists())

    def test_failed_boot_restores_preferences_and_old_identity(self):
        self.baseline()
        def boot(contents, prefix, log):
            if contents == self.new:
                (prefix / "user.reg").write_text("damaged by upgrade")
                raise RuntimeError("injected boot failure")
        with patch.object(RUNTIME, "stop"), patch.object(RUNTIME, "boot", side_effect=boot):
            with self.assertRaisesRegex(RuntimeError, "已恢复旧容器"):
                RUNTIME.migrate(self.new, self.prefix)
        self.assertEqual(RUNTIME.status(self.archived_old, self.prefix), "ready")
        self.assertEqual((self.prefix / "user.reg").read_text(), "old fonts and preferences")
        self.assertEqual(RUNTIME.status(self.new, self.prefix), "upgrade")
        self.assertEqual(len(list(RUNTIME.state_root(self.prefix).glob("backups/*/failed-bottle"))), 1)

    def test_user_can_rollback_after_successful_dependency_checks(self):
        self.baseline()
        with patch.object(RUNTIME, "stop"), patch.object(RUNTIME, "boot"):
            RUNTIME.migrate(self.new, self.prefix)
            (self.prefix / "user.reg").write_text("new preferences")
            RUNTIME.rollback(self.prefix)
        self.assertEqual(RUNTIME.status(self.archived_old, self.prefix), "ready")
        self.assertEqual((self.prefix / "user.reg").read_text(), "old fonts and preferences")

    def test_rollback_cannot_restore_other_prefix_generation(self):
        self.baseline()
        with patch.object(RUNTIME, "stop"), patch.object(RUNTIME, "boot"):
            RUNTIME.migrate(self.new, self.prefix)
            (self.prefix / ".macsw-wine-prefix-id").write_text("replacement-id")
            with self.assertRaisesRegex(RuntimeError, "不匹配"):
                RUNTIME.rollback(self.prefix)

    def test_backup_failure_never_boots_or_changes_receipt(self):
        self.baseline()
        real_clone = RUNTIME.clone
        def clone(source, destination):
            if destination.name == "bottle":
                raise RuntimeError("no APFS space")
            real_clone(source, destination)
        with patch.object(RUNTIME, "clone", side_effect=clone), patch.object(RUNTIME, "stop"), patch.object(RUNTIME, "boot") as boot:
            with self.assertRaisesRegex(RuntimeError, "APFS"):
                RUNTIME.migrate(self.new, self.prefix)
            boot.assert_not_called()
        self.assertEqual(RUNTIME.read_json(RUNTIME.state_root(self.prefix) / "receipt.json"), self.old)

    def test_failed_recovery_leaves_journal_and_backup_for_retry(self):
        self.baseline()
        with patch.object(RUNTIME, "stop"), patch.object(RUNTIME, "boot", side_effect=RuntimeError("failed boot")):
            with self.assertRaisesRegex(RuntimeError, "恢复未完成"):
                RUNTIME.migrate(self.new, self.prefix)
        self.assertEqual(RUNTIME.status(self.new, self.prefix), "recovery")
        root = RUNTIME.state_root(self.prefix)
        with patch.object(RUNTIME, "stop"), patch.object(RUNTIME, "boot"):
            RUNTIME.restore(root, self.prefix, root / "migration.log")
        self.assertEqual(RUNTIME.status(self.archived_old, self.prefix), "ready")

    def test_relocated_app_needs_rebinding_even_if_wine_identity_matches(self):
        self.baseline()
        relocated = self.root / "moved.app/Contents"
        shutil.copytree(self.contents, relocated)
        self.assertEqual(RUNTIME.identity(relocated), RUNTIME.identity(self.contents))
        self.assertEqual(RUNTIME.status(relocated, self.prefix), "upgrade")
        with self.assertRaisesRegex(RuntimeError, "绕过"):
            RUNTIME.baseline(relocated, self.prefix)

    def test_shutdown_uses_recorded_server_never_boots_new_wine(self):
        self.baseline()
        with patch.object(RUNTIME, "stop") as stop, patch.object(RUNTIME, "boot") as boot:
            RUNTIME.shutdown(self.new, self.prefix)
            self.assertEqual(stop.call_args.args[0], self.archived_old)
            boot.assert_not_called()

    def test_stop_failure_never_backs_up_or_boots(self):
        self.baseline()
        with patch.object(RUNTIME, "stop", side_effect=RuntimeError("server won't stop")), patch.object(RUNTIME, "boot") as boot:
            with self.assertRaisesRegex(RuntimeError, "won't stop"):
                RUNTIME.migrate(self.new, self.prefix)
            boot.assert_not_called()
        self.assertFalse((RUNTIME.state_root(self.prefix) / "pending.json").exists())

    def test_corrupt_runtime_refused_before_stopping(self):
        self.baseline()
        (self.new / "Frameworks/wine" / RUNTIME.MODULES["WineLoaderSHA256"]).write_text("corrupt")
        with patch.object(RUNTIME, "stop") as stop:
            with self.assertRaisesRegex(RuntimeError, "校验失败"):
                RUNTIME.migrate(self.new, self.prefix)
            stop.assert_not_called()

    def test_same_identity_upgrade_does_nothing(self):
        self.baseline()
        with patch.object(RUNTIME, "stop") as stop:
            RUNTIME.migrate(self.contents, self.prefix)
            stop.assert_not_called()

    def test_replaced_prefix_requires_new_baseline(self):
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

    def test_unmanaged_other_prefix_is_not_modified(self):
        foreign = self.root / "other-bottle"
        (foreign / "drive_c").mkdir(parents=True)
        self.assertEqual(RUNTIME.status(self.contents, foreign), "unmanaged")
        self.assertFalse(RUNTIME.state_root(foreign).exists())

    def test_pending_journal_prevents_launch_even_if_identity_matches(self):
        self.baseline()
        RUNTIME.write_json(RUNTIME.state_root(self.prefix) / "pending.json", {"incomplete": True})
        with self.assertRaises(RuntimeError):
            RUNTIME.require_ready(self.contents, self.prefix)

    def test_symlink_prefix_rejected(self):
        link = self.root / "link"
        link.symlink_to(self.prefix)
        with self.assertRaisesRegex(RuntimeError, "不安全"):
            RUNTIME.baseline(self.contents, link)


if __name__ == "__main__":
    unittest.main()
