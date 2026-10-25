"""Real resource-seal regression; no Wine, credentials, or user bottle needed."""
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("bytecode_wine_runtime", PROJECT / "scripts/swcli/wine_runtime.py")
RUNTIME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNTIME)


@unittest.skipUnless(sys.platform == "darwin", "macOS resource signatures required")
class PythonResourceSealTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="macsw-bytecode-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / "Probe.app"
        self.contents = self.app / "Contents"
        (self.contents / "MacOS").mkdir(parents=True)
        self.modules = self.contents / "Resources/imports"
        self.modules.mkdir(parents=True)
        # Preserve executable mode, not the system binary's restricted flags.
        shutil.copy("/usr/bin/true", self.contents / "MacOS/Probe")
        (self.modules / "cache_probe.py").write_text("value = 42\n")
        with (self.contents / "Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "test.macsw.bytecode",
                          "CFBundleExecutable": "Probe", "CFBundlePackageType": "APPL"}, stream)
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", str(self.app)],
                       capture_output=True, check=True)

    def import_module(self, flags):
        subprocess.run([sys.executable, *flags, "-c",
                        f"import sys; sys.path.insert(0, {str(self.modules)!r}); import cache_probe; "
                        "assert cache_probe.value == 42"],
                       env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}, check=True)

    def test_isolated_no_bytecode_preserves_signed_resources(self):
        before = sorted(str(path.relative_to(self.app)) for path in self.app.rglob("*"))
        self.import_module(["-I", "-B"])
        self.assertEqual(before, sorted(str(path.relative_to(self.app)) for path in self.app.rglob("*")))
        self.assertFalse(list(self.modules.rglob("*.pyc")))
        RUNTIME.verify_seal(self.contents)

    def test_isolation_ignores_environment_and_preflight_blocks_damaged_app(self):
        self.import_module(["-I"])
        self.assertTrue(list(self.modules.rglob("*.pyc")))
        with patch.object(RUNTIME, "run") as wine:
            for operation in (
                lambda: RUNTIME.stop(self.contents, self.root / "bottle", self.root / "log"),
                lambda: RUNTIME.boot(self.contents, self.root / "bottle", self.root / "log"),
            ):
                with self.assertRaisesRegex(RuntimeError, "签名校验失败"):
                    operation()
            wine.assert_not_called()

    def test_signature_check_timeout_fails_closed(self):
        with patch.object(RUNTIME.subprocess, "run", side_effect=subprocess.TimeoutExpired("codesign", 60)):
            with self.assertRaisesRegex(RuntimeError, "无法验证 App 签名"):
                RUNTIME.verify_seal(self.contents)


if __name__ == "__main__":
    unittest.main()
