"""Offline adapter checks; CAD semantics are owned exclusively by SWCLI."""

import importlib.util
import base64
import json
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import time
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
restore_spec = importlib.util.spec_from_file_location("macsw_cache_diagnostic", PROJECT / "scripts/ci/restore-base.py")
restore_cache = importlib.util.module_from_spec(restore_spec)
restore_spec.loader.exec_module(restore_cache)


class RuntimeWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = (PROJECT / ".github/workflows/build-app.yml").read_text()
        self.build, self.runtime = self.workflow.split("\n  build:\n", 1)[1].split("\n  runtime-test:\n", 1)

    def test_official_actions_use_node24_versions_and_keep_archive_layout(self):
        actions = {
            "actions/checkout@v7": 2,
            "actions/cache@v6": 1,
            "actions/cache/restore@v6": 1,
            "actions/cache/save@v6": 1,
            "actions/upload-artifact@v7": 3,
            "actions/download-artifact@v8": 2,
        }
        for action, count in actions.items():
            self.assertEqual(self.workflow.count("uses: " + action + "\n"), count)
        uploads = self.workflow.split("uses: actions/upload-artifact@v7\n")[1:]
        for upload in uploads:
            step = upload.split("- name:", 1)[0]
            self.assertIn("archive: true", step)
        self.assertNotIn("ACTIONS_ALLOW_USE_UNSECURE_NODE_VERSION", self.workflow)

    def test_build_and_runtime_have_independent_results_and_concurrency(self):
        self.assertIn("run: make test", self.build)
        self.assertIn("make archive", self.build)
        self.assertLess(self.build.index("run: make test"), self.build.index("make archive"))
        self.assertNotIn("make ci", self.build)
        self.assertIn("needs: build", self.runtime)
        self.assertIn("group: macsw-build-${{ github.ref }}", self.build)
        self.assertIn("group: macsw-solidworks-runtime", self.runtime)
        self.assertIn("cancel-in-progress: false", self.runtime)
        self.assertNotIn("continue-on-error", self.workflow)
        self.assertNotIn("swift build", self.runtime)
        self.assertNotIn("make archive", self.runtime)

    def test_private_secrets_are_only_in_master_runtime_job(self):
        self.assertNotIn("secrets.RCLONE_CONFIG_B64", self.build)
        self.assertNotIn("secrets.SW_SERIAL_SOLIDWORKS", self.build)
        guard = self.runtime.split("    steps:", 1)[0]
        self.assertIn("github.repository == 'YJBeetle/MacSW'", guard)
        self.assertIn("github.ref == 'refs/heads/master'", guard)
        self.assertIn("github.event_name == 'push'", guard)
        self.assertIn("github.event_name == 'workflow_dispatch' && inputs.verify_solidworks", guard)
        self.assertNotIn("pull_request", self.workflow)
        self.assertIn("contents: read", guard)
        self.assertNotIn("contents: write", guard)
        self.assertIn("Publish Release Assets (on tag)", self.build)
        self.assertNotIn("Publish Release Assets", self.runtime)

    def test_download_assets_cache_uses_dependency_identity_not_swcli_source_pin(self):
        load = self.build.split("- name: Load build configuration", 1)[1].split("- name:", 1)[0]
        self.assertIn("scripts/ci/cache-identity.py assets", load)
        source_hash = next(line for line in load.splitlines() if "MACSW_ASSETS_HASH:" in line)
        self.assertIn("config/swcli-wheels.tsv", source_hash)
        self.assertIn("scripts/fetch_dependencies.sh", source_hash)
        self.assertIn("patches/wine-crossover/**", source_hash)
        self.assertNotIn("config/versions.env", source_hash)
        step = self.build.split("- name: Cache pinned Wine runtime and 7zz", 1)[1].split("- name:", 1)[0]
        self.assertIn("macsw-runtime-assets-v2-", step)
        self.assertIn("steps.build-config.outputs.runtime_cache_identity", step)
        self.assertNotIn("config/versions.env", step)
        self.assertNotIn("Dependencies/SWCLI", step)

    def test_runtime_downloads_and_verifies_same_run_archives_before_unpacking(self):
        for name in ("MacSW-macOS-App", "MacSW-CI-Helpers"):
            self.assertIn("name: " + name, self.build)
            self.assertIn("name: " + name, self.runtime)
        downloads = self.runtime.split("- name: Download this run's MacSW App artifact", 1)[1].split(
            "- name: Prepare private runtime test bundle", 1)[0]
        self.assertEqual(downloads.count("uses: actions/download-artifact@v8"), 2)
        for override in ("run-id:", "github-token:", "repository:"):
            self.assertNotIn(override, downloads)
        for output in ("app_archive", "app_sha256", "helpers_sha256"):
            self.assertIn("needs.build.outputs." + output, self.runtime)
        self.assertIn('archive="$RUNNER_TEMP/MacSW-build-artifacts/$MACSW_APP_ARCHIVE"', self.runtime)
        for archive in ("archive", "helpers"):
            self.assertLess(self.runtime.index('shasum -a 256 "$' + archive + '"'),
                            self.runtime.index('ditto -x -k "$archive"'))
        self.assertIn('tar -czf build/ci/MacSW-CI-Helpers.tar.gz -C "$binary_dir" MacSWCI MacSWCIRuntime', self.build)
        self.assertIn("scripts/diagnostics/check_bitmap_opengl.c -lopengl32 -lgdi32", self.build)
        self.assertIn("scripts/diagnostics/check_cgl_renderer.c -framework OpenGL", self.build)
        for architecture in ("arm64", "x86_64"):
            self.assertIn("check_cgl_" + architecture, self.build)
        self.assertIn('codesign --verify --verbose=2 "$probe"', self.runtime)
        self.assertIn('check_bitmap_opengl.exe', self.runtime)
        self.assertIn('tar -xzf "$helpers"', self.runtime)
        self.assertIn('test -x "$RUNNER_TEMP/MacSW-runtime/MacSW.app/Contents/MacOS/MacSWCI"', self.runtime)

    def test_official_cache_and_always_cleanup_stay_in_runtime_job(self):
        snapshot = self.runtime.index("- name: Save only verified official base")
        fixtures = self.runtime.index("- name: Prepare temporary licensing and runtime fixtures")
        gates = self.runtime.index("- name: Shared modeling then driving dimensions on one host")
        self.assertLess(snapshot, fixtures)
        self.assertLess(fixtures, gates)
        self.assertIn("TAR_OPTIONS: --same-permissions", self.runtime)
        self.assertNotIn("macsw-installed-base-v3-", self.build)
        self.assertEqual(self.runtime.count("key: macsw-installed-base-v3-"), 2)
        self.assertNotIn("restore-keys:", self.runtime)
        identity = self.runtime.split("- name: Resolve installed base cache identity", 1)[1].split("- name:", 1)[0]
        self.assertIn("scripts/ci/cache-identity.py installed-base", identity)
        self.assertNotIn("'config/versions.env'", identity)
        for step in ("Stop isolated runtime test bottle", "Redact runtime evidence before publication",
                     "Upload sanitized runtime and installer evidence (no license files)"):
            section = self.runtime.split("- name: " + step, 1)[1].split("- name:", 1)[0]
            self.assertIn("if: always()", section)
        upload = self.runtime.split("- name: Upload sanitized runtime", 1)[1]
        self.assertIn("steps.redact-runtime.outcome == 'success'", upload)


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

    def test_log_snapshot_is_bounded_and_preserves_inherited_write_offset(self):
        native_pread = os.pread
        with tempfile.TemporaryFile() as log:
            log.write(b"initial")
            log.flush()
            def append_during_read(fd, size, offset):
                os.write(fd, b" later")
                return native_pread(fd, size, offset)
            with patch.object(ci.os, "pread", side_effect=append_during_read):
                self.assertEqual(ci.snapshot_output(log), "initial")
            self.assertEqual(log.tell(), len(b"initial later"))
            self.assertEqual(native_pread(log.fileno(), 100, 0), b"initial later")

    def test_command_uses_regular_files_and_records_real_exit_and_text(self):
        gate = self.gate()
        def spawn(arguments, **kwargs):
            for name in ("stdout", "stderr"):
                self.assertTrue(stat.S_ISREG(os.fstat(kwargs[name].fileno()).st_mode))
            self.assertNotIn("capture_output", kwargs)
            self.assertEqual(kwargs["env"], gate.env)
            kwargs["stdout"].write("结果\r\n".encode())
            kwargs["stdout"].flush()
            kwargs["stderr"].write(b"diagnostic\xff\r")
            kwargs["stderr"].flush()
            return SimpleNamespace(pid=123, wait=lambda timeout: 0)
        with patch.object(ci.subprocess, "Popen", side_effect=spawn):
            self.assertEqual(gate.command([Path("probe"), "argument"], timeout=60), "结果\n")
        entry = gate.record["commands"][0]
        self.assertTrue(entry["completed"])
        self.assertEqual(entry["unix_pid"], 123)
        self.assertEqual(entry["exit_code"], 0)
        self.assertEqual(entry["stderr"], "diagnostic\ufffd\n")
        self.assertNotIn("running_at_timeout", entry)
        self.assertEqual(json.loads(gate.record_path.read_text())["commands"][0], entry)

    def test_command_returns_without_waiting_for_descendant_log_handles(self):
        gate = self.gate()
        release = self.directory / "release"
        ready = self.directory / "ready"
        done = self.directory / "done"
        child = ("from pathlib import Path; import sys,time; "
                 "release,ready,done=map(Path,sys.argv[1:]); ready.touch(); "
                 "deadline=time.monotonic()+30\n"
                 "while not release.exists() and time.monotonic()<deadline: time.sleep(0.02)\n"
                 "done.touch()\n")
        parent = ("from pathlib import Path; import subprocess,sys,time; "
                  "subprocess.Popen([sys.executable,'-c',sys.argv[1],*sys.argv[2:]]); "
                  "ready=Path(sys.argv[3]); deadline=time.monotonic()+10\n"
                  "while not ready.exists() and time.monotonic()<deadline: time.sleep(0.02)\n"
                  "assert ready.exists(); print('parent done'); print('diagnostic',file=sys.stderr)\n")
        try:
            output = gate.command([sys.executable, "-c", parent, child, release, ready, done], timeout=5)
            self.assertEqual(output, "parent done\n")
            self.assertTrue(ready.exists())
            self.assertFalse(done.exists())  # The descendant still holds both log descriptors.
            self.assertEqual(gate.record["commands"][0]["exit_code"], 0)
            self.assertEqual(gate.record["commands"][0]["stderr"], "diagnostic\n")
        finally:
            release.touch()
            deadline = time.monotonic() + 5
            while ready.exists() and not done.exists() and time.monotonic() < deadline:
                time.sleep(0.02)
        self.assertTrue(done.exists())

    def test_command_success_output_cannot_hide_nonzero_exit(self):
        gate = self.gate()
        with self.assertRaisesRegex(RuntimeError, "Command failed"):
            gate.command([sys.executable, "-c", "print('{\"success\":true}'); raise SystemExit(7)"])
        entry = gate.record["commands"][0]
        self.assertTrue(entry["completed"])
        self.assertEqual(entry["exit_code"], 7)
        self.assertIn('"success":true', entry["stdout"])

    def test_command_real_timeout_remains_failure_and_keeps_partial_logs(self):
        gate = self.gate()
        script = "import sys,time; print('partial',flush=True); print('diagnostic',file=sys.stderr,flush=True); time.sleep(30)"
        with self.assertRaises(subprocess.TimeoutExpired):
            gate.command([sys.executable, "-c", script], timeout=1)
        entry = gate.record["commands"][0]
        self.assertFalse(entry["completed"])
        self.assertTrue(entry["running_at_timeout"])
        self.assertNotEqual(entry["exit_code"], 0)
        self.assertEqual(entry["stdout"], "partial\n")
        self.assertEqual(entry["stderr"], "diagnostic\n")
        with self.assertRaises(ProcessLookupError):
            os.kill(entry["unix_pid"], 0)

    def test_command_exit_racing_with_timeout_is_not_reclassified_as_success(self):
        gate = self.gate()
        with patch.object(ci.subprocess, "Popen") as spawn:
            process = spawn.return_value
            process.pid = 123
            process.returncode = 0
            process.poll.return_value = 0
            process.wait.side_effect = subprocess.TimeoutExpired(["probe"], 60)
            with self.assertRaises(subprocess.TimeoutExpired):
                gate.command(["probe"], timeout=60)
            process.kill.assert_not_called()
        entry = gate.record["commands"][0]
        self.assertFalse(entry["completed"])
        self.assertFalse(entry["running_at_timeout"])
        self.assertEqual(entry["exit_code"], 0)
        self.assertEqual(entry["error"], "Outer command deadline exceeded")

    def test_command_termination_timeout_is_reported_without_hiding_original_failure(self):
        gate = self.gate()
        original = subprocess.TimeoutExpired(["probe"], 60)
        with patch.object(ci.subprocess, "Popen") as spawn:
            process = spawn.return_value
            process.pid = 123
            process.returncode = None
            process.poll.return_value = None
            process.wait.side_effect = [original, subprocess.TimeoutExpired(["probe"], 5)]
            with self.assertRaises(subprocess.TimeoutExpired) as caught:
                gate.command(["probe"], timeout=60)
            self.assertIs(caught.exception, original)
            process.kill.assert_called_once_with()
        entry = gate.record["commands"][0]
        self.assertFalse(entry["completed"])
        self.assertTrue(entry["running_at_timeout"])
        self.assertIsNone(entry["exit_code"])
        self.assertEqual(entry["cleanup_error"], "Command did not exit after termination")

    def test_process_metrics_keep_only_numeric_fields_of_known_wine_processes(self):
        output = "\n".join([
            r"42 75.5 12:34.50 4096 Rs C:\Program Files\SOLIDWORKS\sldworks.exe",
            r"43 0.0 0:00.10 1024 S C:\MacSW\Python311\python.exe",
            "44 1.5 1:02:03 512 S " + str(self.app / "Contents/Frameworks/wine/bin/wineserver"),
            "45 0.0 0:00 100 S /usr/bin/python3",
            r"46 0.0 0:00 100 S C:\private\unknown.exe",
            r"47 0.0 0:00 100 S C:\MacSW\Python311\python.exe --token private",
        ])
        result = ci.wine_process_metrics(output, self.app)
        self.assertEqual([row["unix_pid"] for row in result], [42, 43, 44])
        self.assertEqual(result[0], {"name": "sldworks.exe", "unix_pid": 42, "cpu_percent": 75.5,
                                     "cpu_seconds": 754.5, "resident_kib": 4096, "state": "Rs"})
        self.assertEqual(result[2]["cpu_seconds"], 3723)
        self.assertNotIn("private", json.dumps(result))
        self.assertNotIn("command", json.dumps(result))
        self.assertNotIn(str(self.app), json.dumps(result))

    def test_process_metrics_reject_nonfinite_or_malformed_numbers(self):
        output = "\n".join(
            prefix + r" C:\MacSW\Python311\python.exe" for prefix in [
                "bad 0 0:00 100 S", "0 0 0:00 100 S", "1 nan 0:00 100 S", "1 inf 0:00 100 S",
                "1 0 nan 100 S", "1 0 0:00 -1 S", "1 -1 0:00 100 S", "1 0 0:00 100 secret123",
                "1 0 0:00:00:00 100 S", "1 0 1e308:00:00 100 S",
            ])
        self.assertEqual(ci.wine_process_metrics(output, self.app), [])

    def test_host_metrics_capture_without_com_or_forwarded_secrets(self):
        gate = self.gate()
        gate.record["phase"] = "visible.modeling"
        metrics = ci.HostMetrics(gate, "visible")
        with patch.object(ci.os, "getloadavg", return_value=(1, 2, 3)), \
                patch.object(ci.shutil, "disk_usage", return_value=SimpleNamespace(free=12345)), \
                patch.object(ci.subprocess, "run", return_value=SimpleNamespace(
                    returncode=0, stdout=r"42 1 0:00 100 S C:\MacSW\Python311\python.exe", stderr="private")) as run:
            metrics.capture()
            metrics.capture()
        self.assertEqual(run.call_args.args[0], ["/bin/ps", "-axo", "pid=,pcpu=,time=,rss=,stat=,comm="])
        self.assertEqual(run.call_args.kwargs["timeout"], 5)
        self.assertEqual(run.call_args.kwargs["env"], {"LC_ALL": "C", "LANG": "C"})
        text = (gate.evidence / "visible-host-metrics.log").read_text()
        records = [json.loads(line) for line in text.splitlines()]
        self.assertEqual(len(records), 2)
        self.assertEqual(records[0]["phase"], "visible.modeling")
        self.assertEqual(records[0]["free_disk_bytes"], 12345)
        self.assertEqual(records[0]["load_average"], [1, 2, 3])
        self.assertNotIn("private", text)

    def test_host_metrics_tool_failure_is_a_diagnostic_gap_not_a_gate_failure(self):
        gate = self.gate()
        metrics = ci.HostMetrics(gate, "visible")
        with patch.object(ci.subprocess, "run", side_effect=OSError("private command line")):
            metrics.capture()
        record = json.loads((gate.evidence / "visible-host-metrics.log").read_text())
        self.assertEqual(record["diagnostic_error"], "OSError")
        self.assertNotIn("private", json.dumps(record))
        self.assertFalse(gate.record["completed"])

    def stall_metrics(self):
        gate = self.gate()
        gate.record["hosts"] = [{"mode": "visible", "host": {"owned_by_daemon": True}}]
        metrics = ci.HostMetrics(gate, "visible")
        event = {"event": "swcli.native-call", "worker_pid": 32, "request_id": "request-1",
                 "sequence": 78, "phase": "begin", "call": "FirstFeature", "stage": "read",
                 "operation": "feature.extrude", "monotonic_seconds": 999999}
        path = gate.evidence / "visible-daemon.log"
        path.write_text("Wine diagnostics\n" + json.dumps(event) + "\n")
        return gate, metrics, event, path, [{"name": "sldworks.exe", "unix_pid": 42}]

    def test_native_stall_samples_one_owned_host_after_unchanged_boundary(self):
        gate, metrics, event, path, targets = self.stall_metrics()
        with patch.object(ci.time, "monotonic", side_effect=[10, 39, 40]), \
                patch.object(ci.subprocess, "run", return_value=SimpleNamespace(returncode=0)) as run:
            self.assertIsNone(metrics.sample_stalled_host(targets))
            self.assertIsNone(metrics.sample_stalled_host(targets))
            result = metrics.sample_stalled_host(targets)
            self.assertIsNone(metrics.sample_stalled_host(targets))
        self.assertEqual(result["call"], "FirstFeature")
        self.assertEqual(result["request_id"], "request-1")
        run.assert_called_once_with(
            ["/usr/bin/sample", "42", "2", "10", "-file", str(gate.evidence / "visible-native-stall.log")],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=15, env={"LC_ALL": "C", "LANG": "C"})
        self.assertFalse(gate.record["completed"])

    def test_native_stall_end_or_new_call_resets_observation_without_sampling(self):
        _, metrics, event, path, targets = self.stall_metrics()
        with patch.object(ci.time, "monotonic", side_effect=[10, 100, 200, 220]), \
                patch.object(ci.subprocess, "run") as run:
            self.assertIsNone(metrics.sample_stalled_host(targets))
            event["phase"] = "end"
            path.write_text(json.dumps(event) + "\n")
            self.assertIsNone(metrics.sample_stalled_host(targets))
            event.update(phase="begin", sequence=79)
            path.write_text(json.dumps(event) + "\n")
            self.assertIsNone(metrics.sample_stalled_host(targets))
            self.assertIsNone(metrics.sample_stalled_host(targets))
        run.assert_not_called()

    def test_native_stall_never_samples_shared_ambiguous_missing_or_stopped_hosts(self):
        gate, metrics, event, path, targets = self.stall_metrics()
        metrics.last_native_event = (32, "request-1", 78, "begin")
        metrics.last_native_change = 0
        with patch.object(ci.time, "monotonic", return_value=100), \
                patch.object(ci.subprocess, "run") as run:
            gate.record["hosts"][0]["host"]["owned_by_daemon"] = False
            self.assertIsNone(metrics.sample_stalled_host(targets))
            gate.record["hosts"][0]["host"]["owned_by_daemon"] = True
            for processes in ([], targets * 2):
                self.assertIsNone(metrics.sample_stalled_host(processes))
            metrics.stopped.set()
            self.assertIsNone(metrics.sample_stalled_host(targets))
        run.assert_not_called()

    def test_native_stall_tool_failure_is_once_only_and_keeps_private_text_out(self):
        _, metrics, event, path, targets = self.stall_metrics()
        with patch.object(ci.time, "monotonic", side_effect=[10, 40]), \
                patch.object(ci.subprocess, "run", side_effect=OSError("private native text")) as run:
            self.assertIsNone(metrics.sample_stalled_host(targets))
            result = metrics.sample_stalled_host(targets)
            self.assertIsNone(metrics.sample_stalled_host(targets))
        self.assertEqual(result["diagnostic_error"], "OSError")
        self.assertEqual(result["request_id"], "request-1")
        self.assertEqual(result["unix_pid"], 42)
        self.assertEqual(result["call"], "FirstFeature")
        self.assertFalse(result["evidence_present"])
        self.assertNotIn("private", json.dumps(result))
        run.assert_called_once()

    def test_native_stall_timeout_retains_boundary_and_partial_report(self):
        gate, metrics, event, path, targets = self.stall_metrics()
        output = gate.evidence / "visible-native-stall.log"
        def sample(*args, **kwargs):
            output.write_text("partial sample report\n")
            raise subprocess.TimeoutExpired(args[0], kwargs["timeout"], stderr="private error")
        with patch.object(ci.time, "monotonic", side_effect=[10, 40]), \
                patch.object(ci.subprocess, "run", side_effect=sample) as run:
            self.assertIsNone(metrics.sample_stalled_host(targets))
            result = metrics.sample_stalled_host(targets)
            self.assertIsNone(metrics.sample_stalled_host(targets))
        self.assertEqual(result["diagnostic_error"], "TimeoutExpired")
        self.assertEqual(result["request_id"], "request-1")
        self.assertEqual(result["sequence"], 78)
        self.assertEqual(result["tool_timeout_seconds"], 15)
        self.assertTrue(result["evidence_present"])
        self.assertNotIn("private", json.dumps(result))
        run.assert_called_once()

    def test_native_stall_tolerates_missing_malformed_and_no_native_boundary(self):
        _, metrics, event, path, targets = self.stall_metrics()
        with patch.object(ci.subprocess, "run") as run:
            for text in ("", "Wine diagnostics only\n", '{"event": "swcli.native-call", broken\n'):
                path.write_text(text)
                self.assertIsNone(metrics.sample_stalled_host(targets))
            path.unlink()
            self.assertIsNone(metrics.sample_stalled_host(targets))
        run.assert_not_called()

    def test_metrics_context_stops_sampler_and_preserves_original_gate_error(self):
        metrics = ci.HostMetrics(self.gate(), "visible")
        with patch.object(metrics.thread, "start") as start, patch.object(metrics.thread, "join") as join:
            with self.assertRaisesRegex(RuntimeError, "original gate error"):
                with metrics:
                    raise RuntimeError("original gate error")
        start.assert_called_once_with()
        join.assert_called_once_with(timeout=21)
        self.assertTrue(metrics.stopped.is_set())

    def test_metrics_thread_creation_failure_does_not_block_shared_gate(self):
        metrics = ci.HostMetrics(self.gate(), "visible")
        with patch.object(metrics.thread, "start", side_effect=RuntimeError("no thread")), \
                patch.object(metrics.thread, "join") as join:
            with metrics:
                pass
        join.assert_not_called()

    def test_runtime_captures_wine_com_diagnostics_without_credentials(self):
        gate = self.gate()
        self.assertEqual(gate.env["WINEDEBUG"], "-all,err+ole,warn+ole,+seh,+loaddll,+timestamp,+wgl")
        self.assertNotIn("+opengl", gate.env["WINEDEBUG"])
        self.assertEqual(gate.env["SWCLI_TRACE_NATIVE_CALLS"], "1")
        # One COM activation, bounded below swclid's 180-second startup budget.
        self.assertEqual(gate.env["WINE_SOLIDWORKS_STARTUP_TIMEOUT"], "150")
        self.assertNotIn("SW_SERIAL_SOLIDWORKS", gate.env)
        self.assertNotIn("RCLONE_CONFIG_B64", gate.env)

    def test_non_ci_and_user_app_are_rejected(self):
        with patch.dict(os.environ, {"GITHUB_ACTIONS": "false"}):
            with self.assertRaisesRegex(RuntimeError, "runner required"):
                self.gate()
        with self.assertRaisesRegex(RuntimeError, "isolated CI"):
            ci.RuntimeGate(Path("/Applications/MacSW.app"), self.root / "evidence")

    def test_acquisition_evidence_does_not_claim_host_readiness(self):
        gate = self.gate()
        event = {"action": "daemon.startup", "ok": True, "phase": "host-acquired",
                 "host": {"owned_by_daemon": True, "process_id": 472}}
        (gate.evidence / "visible-daemon.log").write_text(
            "Wine diagnostic\n{invalid\n" + json.dumps(event) + "\n"
            + json.dumps({"action": "daemon.serve", "ok": False}) + "\n")
        gate.collect_startup_evidence()
        self.assertEqual(gate.record["host_acquisitions"], [{"mode": "visible", "host": event["host"]}])
        self.assertEqual(gate.record["hosts"], [])
        self.assertFalse(gate.record["completed"])

    def test_runtime_preparation_precedes_one_daemon_activation(self):
        gate = self.gate()
        host = {"platform": "macos-wine", "owned_by_daemon": True,
                "shared_interactive": False, "visible": True, "process_id": 472}
        with patch.object(gate, "command") as command, patch.object(gate, "host", return_value=host), \
                patch.object(ci, "verify_swcli_deployment", return_value={"verified": True, "files": 3, "sha256": "a" * 64}) as deployment, \
                patch.object(ci.subprocess, "Popen") as spawn:
            spawn.return_value.poll.return_value = None
            self.assertEqual(gate.start("visible"), host)
        self.addCleanup(gate.log.close)
        self.assertEqual([entry.args[0] for entry in command.call_args_list], [
            [gate.runtime_helper, "prepare", "visible"], [gate.helper, "prepare"],
            [gate.runtime_helper, "inspect", "visible"]])
        self.assertEqual(spawn.call_count, 1)
        deployment.assert_called_once_with(gate.app, gate.prefix)
        self.assertEqual(gate.record["swcli_deployments"][0]["mode"], "visible")
        self.assertNotIn("--attach-existing", spawn.call_args.args[0])
        self.assertEqual(spawn.call_args.kwargs["env"]["SWCLI_TRACE_NATIVE_CALLS"], "1")
        self.assertIs(spawn.call_args.kwargs["stdout"], gate.log)
        self.assertEqual(spawn.call_args.kwargs["stderr"], ci.subprocess.STDOUT)

    def test_host_helper_reuses_core_and_is_not_a_public_or_cached_payload(self):
        helper = (PROJECT / "macos/Bootstrap/Sources/MacSWCIRuntime/MacSWCIRuntime.swift").read_text()
        package = (PROJECT / "scripts/package_app.sh").read_text()
        workflow = (PROJECT / ".github/workflows/build-app.yml").read_text()
        self.assertIn("SolidWorksResourceMonitorService()", helper)
        self.assertIn("PrerequisiteService.prepareSWCLI(bundleURL: Bundle.main.bundleURL, prefix: paths.bottle)", helper)
        self.assertIn("monitor.setDisabled(true, paths: paths)", helper)
        self.assertIn("wine.windowsPath(for: mono, prefix: paths.bottle)", helper)
        self.assertIn('env["GITHUB_ACTIONS"] == "true"', helper)
        self.assertIn("Bundle.main.bundleURL.resolvingSymlinksInPath()", helper)
        self.assertNotIn("AppPaths.live", helper)
        self.assertNotIn('"Z:"', helper)
        self.assertIn("WineService.vcLibraries", helper)
        self.assertNotIn("MacSWCIRuntime", package)
        installer_hash = next(line for line in workflow.splitlines() if "MACSW_INSTALLER_HASH:" in line)
        self.assertNotIn("Sources/MacSWCIRuntime", installer_hash)
        self.assertIn("--product MacSWCIRuntime", workflow)

    def test_stale_runtime_fails_before_license_preparation_or_host_start(self):
        gate = self.gate()
        with patch.object(gate, "command") as command, \
                patch.object(ci, "verify_swcli_deployment", side_effect=RuntimeError("stale runtime")), \
                patch.object(ci.subprocess, "Popen") as spawn:
            with self.assertRaisesRegex(RuntimeError, "stale runtime"):
                gate.start("visible")
        command.assert_called_once_with([gate.runtime_helper, "prepare", "visible"])
        spawn.assert_not_called()
        self.assertEqual(gate.record["swcli_deployments"], [])

    def test_runtime_inventory_requires_exact_current_app_payload(self):
        gate = self.gate()
        source = gate.app / "Contents/Resources/SWCLI/runtime/Python311"
        destination = gate.prefix / "drive_c/MacSW/Python311"
        for name in ("python.exe", "pythonw.exe", "Lib/site-packages/swcli/__main__.py"):
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
        shutil.copytree(source, destination)
        proof = ci.verify_swcli_deployment(gate.app, gate.prefix)
        self.assertTrue(proof["verified"])
        self.assertEqual(proof["files"], 3)
        self.assertEqual(len(proof["sha256"]), 64)
        installed = destination / "Lib/site-packages/swcli/__main__.py"
        installed.write_bytes(b"older daemon")
        with self.assertRaisesRegex(RuntimeError, "differs"):
            ci.verify_swcli_deployment(gate.app, gate.prefix)
        installed.unlink()
        installed.symlink_to(source / "Lib/site-packages/swcli/__main__.py")
        with self.assertRaisesRegex(RuntimeError, "symlink"):
            ci.verify_swcli_deployment(gate.app, gate.prefix)
        installed.unlink()
        with self.assertRaisesRegex(RuntimeError, "incomplete"):
            ci.verify_swcli_deployment(gate.app, gate.prefix)

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
                patch.object(gate, "verify_bitmap_driver", side_effect=lambda: events.append("bitmap-driver")), \
                patch.object(ci, "HostMetrics") as metrics, \
                patch.object(gate, "start", side_effect=lambda mode: events.append("start:" + mode) or host), \
                patch.object(gate, "same_host", side_effect=lambda expected: self.assertEqual(expected, host)), \
                patch.object(gate, "command", side_effect=command), \
                patch.object(gate, "windows_path", return_value="Q:\\models"), \
                patch.object(gate, "collect_evidence"), \
                patch.object(gate, "stop", side_effect=lambda: events.append("stop")):
            gate.run()
        self.assertEqual([call.args for call in metrics.call_args_list],
                         [(gate, "visible"), (gate, "visible"), (gate, "hidden"), (gate, "hidden")])
        self.assertEqual(events, ["bitmap-driver", "start:visible", "verify-modeling.py", "verify-driving-dimensions.py", "stop",
                                  "start:hidden", "verify-modeling.py", "verify-driving-dimensions.py", "stop"])
        self.assertTrue(gate.record["completed"])

    def test_native_bitmap_driver_requires_all_eight_actual_pixel_cases(self):
        records = [{"bpp": bpp, "width": width, "top_down": top_down, "success": True,
                    "stage": "complete", "red_pixels": width * 8, "gl_error": 0,
                    "depth": 24, "stencil": 8}
                   for bpp in (24, 32) for width in (7, 8) for top_down in (False, True)]
        gate = self.gate()
        probe = gate.app / "Contents/MacOS/check_bitmap_opengl.exe"
        with self.assertRaisesRegex(RuntimeError, "native bitmap probe is missing"):
            gate.verify_bitmap_driver()
        probe.parent.mkdir(parents=True)
        probe.touch()
        def check(items, success):
            with patch.object(gate, "windows_path", return_value="M:\\MacSW.app\\Contents\\MacOS\\check_bitmap_opengl.exe"), \
                    patch.object(gate, "inspect_cgl_renderers") as inspect, \
                    patch.object(gate, "command", return_value='\n'.join(map(json.dumps, items))) as command:
                if success:
                    gate.verify_bitmap_driver()
                    self.assertEqual(gate.record["bitmap_driver"], records)
                    self.assertEqual(command.call_args.kwargs["timeout"], 60)
                else:
                    with self.assertRaisesRegex(RuntimeError, "verification failed"):
                        gate.verify_bitmap_driver()
                inspect.assert_called_once_with()
        check(records, True)
        check(records[:-1], False)
        check(records + [records[0]], False)
        check(records[:-1] + [records[0]], False)
        for field, value in (("success", False), ("gl_error", 1), ("red_pixels", 0),
                             ("depth", 0), ("stencil", 0), ("stage", "create-context")):
            failed = [dict(row) for row in records]
            failed[0][field] = value
            check(failed, False)

    def test_cgl_observations_preserve_unavailable_modes_and_both_architectures(self):
        gate = self.gate()
        records = [{"kind": "context", "stage": "choose-pixel-format", "cgl_error": 10002}]
        for architecture in ("arm64", "x86_64"):
            probe = gate.app / "Contents/MacOS" / ("check_cgl_" + architecture)
            probe.parent.mkdir(parents=True, exist_ok=True)
            probe.touch()
        with patch.object(gate, "command", return_value=json.dumps(records[0])) as command:
            gate.inspect_cgl_renderers()
        self.assertEqual(gate.record["cgl_renderers"], {arch: records for arch in ("arm64", "x86_64")})
        self.assertEqual(command.call_count, 2)
        self.assertEqual(command.call_args.kwargs["timeout"], 30)
        self.assertNotIn("bitmap_driver", gate.record)
        self.assertFalse(gate.record["completed"])

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

    def test_installation_log_collection_is_whitelisted_and_decodes_utf16(self):
        logs = self.root / "app-support/logs"
        logs.mkdir()
        (logs / "install_msi.log").write_text("MSI failure: fake serial")
        (logs / "vcredist-x64_000_vcRuntimeMinimum_x64.log").write_bytes("Error 0x80070656".encode("utf-16"))
        (logs / "rclone.log").write_text("credential")
        (logs / "license.dat").write_text("private license")
        (logs / "language-wine.log").symlink_to(logs / "rclone.log")
        media.collect_installation_logs(self.root)
        evidence = self.root / "evidence/installer-logs"
        self.assertEqual({path.name for path in evidence.iterdir()}, {"install_msi.log", "vc-installer-0.log"})
        self.assertEqual((evidence / "vc-installer-0.log").read_text(), "Error 0x80070656")
        self.assertEqual(privacy.redact((evidence / "install_msi.log").read_text(),
                                       privacy.sensitive_values({"SW_SERIAL_SOLIDWORKS": "fake serial"})),
                         "MSI failure: fake serial")

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

    def test_publication_retains_authorized_fake_serial_but_redacts_drive_tokens(self):
        serial = "ABCD-EFGH-IJKL-MNOP-QRST-UVWX"
        configuration = '[gdrive]\ntype = drive\ntoken = {"access_token":"private-access-token","refresh_token":"private-refresh-token"}\n'
        values = privacy.sensitive_values({"SW_SERIAL_SOLIDWORKS": serial,
                                          "RCLONE_CONFIG_B64": base64.b64encode(configuration.encode()).decode()})
        for value in ("private-access-token", "private-refresh-token"):
            self.assertEqual(privacy.redact(value, values), "[REDACTED]")
        for value in (serial, serial.replace("-", ""), serial.replace("-", " "),
                      "SOLIDWORKSSERIALNUMBER=" + serial):
            self.assertEqual(privacy.redact(value, values), value)
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

    def test_complete_base_cache_retains_fake_serial_but_removes_logs_and_per_run_mappings(self):
        bottle, serial = self.official_base()
        base_cache.export_snapshot("context")
        snapshot = self.root / "base-cache/bottle"
        self.assertEqual((snapshot / "system.reg").read_bytes(), (bottle / "system.reg").read_bytes())
        self.assertIn(serial.replace("-", ""), (bottle / "system.reg").read_text())
        self.assertFalse((snapshot / "install.log").exists())
        self.assertFalse((snapshot / "drive_c/windows/temp").exists())
        self.assertTrue((snapshot / "dosdevices/c:").is_symlink())
        self.assertFalse((snapshot / "dosdevices/z:").is_symlink())
        shutil.rmtree(bottle)
        base_cache.restore_snapshot("context")
        self.assertTrue((bottle / "drive_c/Program Files/SOLIDWORKS/SLDWORKS.exe").is_file())
        self.assertIn(serial.replace("-", ""), (bottle / "system.reg").read_text())
        self.assertEqual(json.loads((self.root / "evidence/cache.json").read_text())["source"],
                         "installed-base-cache")

    def test_private_fixtures_and_license_files_block_cache_publication(self):
        bottle, serial = self.official_base()
        (self.root / "evidence/setup.json").write_text(json.dumps({"completed": True, "fixture_ready": True}))
        with self.assertRaisesRegex(RuntimeError, "before fixture injection"):
            base_cache.export_snapshot("context")
        (self.root / "evidence/setup.json").write_text(json.dumps({"completed": True, "fixture_ready": False}))
        (bottle / "license.dat").write_bytes(b"private license")
        with self.assertRaisesRegex(RuntimeError, "License/configuration"):
            base_cache.export_snapshot("context")
        self.assertFalse((self.root / "base-cache").exists())

    def test_base_cache_excludes_independently_deployed_swcli_without_changing_live_bottle(self):
        bottle, _ = self.official_base()
        runtime = bottle / "drive_c/MacSW/Python311"
        runtime.mkdir(parents=True)
        (runtime / "python.exe").write_bytes(b"old deployment")
        base_cache.export_snapshot("context")
        snapshot = self.root / "base-cache/bottle"
        self.assertFalse((snapshot / "drive_c/MacSW/Python311").exists())
        self.assertEqual((runtime / "python.exe").read_bytes(), b"old deployment")
        manifest = json.loads((self.root / "base-cache/manifest.json").read_text())
        self.assertEqual(manifest["format"], 3)
        self.assertFalse(any("macsw/python311" in name.lower() for name in manifest["files"]))
        # A cache cannot reintroduce a stale deployment, even if its manifest
        # claims those bytes are intact. Both directories and symlinks fail.
        injected = snapshot / "drive_c/MacSW/Python311"
        injected.mkdir()
        with self.assertRaisesRegex(RuntimeError, "SWCLI deployment"):
            base_cache.inventory(snapshot)
        injected.rmdir()
        injected.symlink_to(runtime, target_is_directory=True)
        with self.assertRaisesRegex(RuntimeError, "SWCLI deployment"):
            base_cache.inventory(snapshot)

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

    def test_restore_diagnostic_preserves_fail_closed_validation_and_hides_paths(self):
        bottle, _ = self.official_base()
        base_cache.export_snapshot("context")
        shutil.rmtree(bottle)
        (self.root / "base-cache/bottle/system.reg").write_text("tampered private contents")
        with self.assertRaisesRegex(RuntimeError, "integrity"):
            restore_cache.restore("context")
        evidence = (self.root / "evidence/cache-restore-failure.json").read_text()
        result = json.loads(evidence)
        self.assertEqual(result["error_category"], "inventory-mismatch")
        self.assertEqual(result["inventory_difference"]["changed_fields"], {"sha256": 1})
        self.assertNotIn("system.reg", evidence)
        self.assertNotIn("tampered", evidence)
        self.assertNotIn(str(self.root), evidence)
        self.assertFalse(bottle.exists())

    def test_cache_extraction_preserves_modes_without_relaxing_integrity(self):
        workflow = (PROJECT / ".github/workflows/build-app.yml").read_text()
        restore_step = workflow.split("- name: Restore official installed bottle cache", 1)[1].split("- name:", 1)[0]
        self.assertIn("TAR_OPTIONS: --same-permissions", restore_step)
        tar = shutil.which("gtar")
        if tar is None:
            self.skipTest("GNU tar required for Actions cache extraction regression")
        bottle, _ = self.official_base()
        (bottle / "system.reg").chmod(0o666)
        base_cache.export_snapshot("context")
        shutil.rmtree(bottle)
        snapshot = self.root / "base-cache"
        archive = self.directory / "official-base.tar"
        subprocess.run([tar, "-cf", str(archive), "-C", str(self.root), "base-cache"], check=True)
        extract = ["bash", "-c", 'umask 022; exec "$@"', "cache-extract", tar,
                   "-xf", str(archive), "-C", str(self.root)]
        environment = dict(os.environ)
        environment.pop("TAR_OPTIONS", None)
        shutil.rmtree(snapshot)
        subprocess.run(extract, env=environment, check=True)
        self.assertEqual((snapshot / "bottle/system.reg").stat().st_mode & 0o777, 0o644)
        with self.assertRaisesRegex(RuntimeError, "integrity"):
            restore_cache.restore("context")
        self.assertFalse(bottle.exists())
        shutil.rmtree(snapshot)
        environment["TAR_OPTIONS"] = "--same-permissions"
        subprocess.run(extract, env=environment, check=True)
        restore_cache.restore("context")
        self.assertEqual((bottle / "system.reg").stat().st_mode & 0o777, 0o666)

    def test_restore_diagnostic_reports_copy_errno_without_error_text(self):
        bottle, _ = self.official_base()
        base_cache.export_snapshot("context")
        shutil.rmtree(bottle)
        error = shutil.Error([("private/source", "private/destination", "[Errno 28] private error text")])
        with patch.object(restore_cache.cache.shutil, "copytree", side_effect=error):
            with self.assertRaises(shutil.Error):
                restore_cache.restore("context")
        evidence = (self.root / "evidence/cache-restore-failure.json").read_text()
        result = json.loads(evidence)
        self.assertEqual(result["error_category"], "copy-error")
        self.assertEqual(result["copy_errnos"], {"28": 1})
        self.assertEqual(result["inventory_difference"]["changed_files"], 0)
        self.assertNotIn("private", evidence)

    def test_restore_diagnostic_does_not_turn_failure_into_success(self):
        bottle, _ = self.official_base()
        base_cache.export_snapshot("context")
        shutil.rmtree(bottle)
        restore_cache.restore("context")
        self.assertTrue(bottle.exists())
        self.assertFalse((self.root / "evidence/cache-restore-failure.json").exists())

    def test_authorized_fake_serial_does_not_rewrite_hex_hives_or_binary_data(self):
        bottle, serial = self.official_base()
        text = "prefix\0" + serial.replace("-", "").lower() + "\0suffix\0\0"
        payload = ",".join(format(byte, "02x") for byte in text.encode("utf-16le"))
        hive = bottle / "user.reg"
        # Include a continuation exactly as Wine/.reg multi-string text may use.
        payload = payload[:90] + "\\\n  " + payload[90:]
        hive.write_text('"Serials"=hex(7):' + payload + "\n")
        binary = bottle / "installer-state.bin"
        binary.write_bytes(text.encode("utf-16le"))
        base_cache.export_snapshot("context")
        self.assertEqual((self.root / "base-cache/bottle/user.reg").read_bytes(), hive.read_bytes())
        self.assertEqual((self.root / "base-cache/bottle/installer-state.bin").read_bytes(), binary.read_bytes())


if __name__ == "__main__":
    unittest.main()
