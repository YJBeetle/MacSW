"""Prepare MacSW hosts and run SWCLI-owned gates sequentially on the same COM host.

No CAD test operations or geometry assertions belong here. Shared gate scripts
and assertions live in the pinned SWCLI submodule. Paths are converted by the
packaged helper using actual bottle drive mappings, never by assuming Z:.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import math
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import time

PROJECT = Path(__file__).resolve().parents[2]
SHARED_GATES = ("verify-modeling.py", "verify-driving-dimensions.py")
# Hosted software rendering is slower than local hardware. These are CI-only
# limits; the shared assertions and SWCLI product defaults remain unchanged.
REQUEST_TIMEOUT_SECONDS = 300
STARTUP_TIMEOUT_SECONDS = 300
SHARED_GATE_TIMEOUT_SECONDS = {"modeling": 1800, "driving": 3600}
SAMPLE_TIMEOUT_SECONDS = 30


def runtime_inventory(directory):
    """Exact public runtime bytes; do not follow symlinks or accept empty trees."""
    if directory.is_symlink() or not directory.is_dir():
        raise RuntimeError("SWCLI runtime directory is unavailable")
    files = {}
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            raise RuntimeError("SWCLI runtime contains a symlink")
        if path.is_dir():
            continue
        if not path.is_file():
            raise RuntimeError("SWCLI runtime contains a non-file entry")
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            while block := stream.read(1024 * 1024):
                digest.update(block)
        files[path.relative_to(directory).as_posix()] = digest.hexdigest()
    required = ("python.exe", "pythonw.exe", "Lib/site-packages/swcli/__main__.py")
    if any(name not in files for name in required):
        raise RuntimeError("SWCLI runtime is incomplete")
    return files


def verify_swcli_deployment(app, prefix):
    source = runtime_inventory(app / "Contents/Resources/SWCLI/runtime/Python311")
    installed = runtime_inventory(prefix / "drive_c/MacSW/Python311")
    if installed != source:
        raise RuntimeError("Installed SWCLI runtime differs from this run's App")
    digest = hashlib.sha256(json.dumps(source, sort_keys=True).encode()).hexdigest()
    return {"verified": True, "files": len(source), "sha256": digest}


def wine_process_metrics(output, app):
    """Keep numeric metrics of known Wine processes, never their arguments."""
    processes = []
    server = str(app / "Contents/Frameworks/wine/bin/wineserver")
    for line in output.splitlines():
        fields = line.split(None, 5)
        if len(fields) != 6:
            continue
        command = fields[5]
        # On this fresh, isolated CI VM these Windows paths are our Wine host.
        # Unix Python/runner processes and arbitrary command lines are excluded.
        name = command.rsplit("\\", 1)[-1].lower()
        if command == server:
            name = "wineserver"
        elif not (len(command) > 3 and command[1:3] == ":\\"
                  and name in ("sldworks.exe", "python.exe", "pythonw.exe")):
            continue
        try:
            pid, cpu, memory = int(fields[0]), float(fields[1]), int(fields[3])
            clock = list(map(float, fields[2].split(":")))
            if not 1 <= len(clock) <= 3 or not all(math.isfinite(n) and n >= 0 for n in clock):
                continue
            cpu_seconds = sum(n * 60 ** i for i, n in enumerate(reversed(clock)))
            if pid <= 0 or memory < 0 or not math.isfinite(cpu) or cpu < 0 or not math.isfinite(cpu_seconds):
                continue
        except (ValueError, OverflowError):
            continue
        state = fields[4]
        if not state or any(c not in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+<>=-" for c in state):
            continue
        processes.append({"name": name, "unix_pid": pid, "cpu_percent": cpu,
                          "cpu_seconds": cpu_seconds, "resident_kib": memory, "state": state})
    return processes


class HostMetrics:
    """Best-effort CI observations; no COM, process control or gate decisions."""

    def __init__(self, gate, mode, interval_seconds=15):
        self.gate = gate
        self.mode = mode
        self.interval = interval_seconds
        self.started_at = time.monotonic()
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.observe, daemon=True)
        self.started = False
        self.last_progress_seconds = None
        self.last_native_event = None
        self.last_native_change = time.monotonic()
        self.sampled = False

    def sample_stalled_host(self, processes):
        """One read-only native sample after an unchanged call boundary for 30s."""
        if self.sampled or self.stopped.is_set():
            return None
        path = self.gate.evidence / (self.mode + "-daemon.log")
        try:
            # Do not consume/move the daemon's writer offset or copy huge logs.
            with path.open("rb") as source:
                source.seek(max(0, os.fstat(source.fileno()).st_size - 128 * 1024))
                lines = source.read().decode("utf-8", errors="replace").splitlines()
            event = next(json.loads(line) for line in reversed(lines)
                         if line.startswith('{"event": "swcli.native-call"'))
            key = (event["worker_pid"], event["request_id"], event["sequence"], event["phase"])
            now = time.monotonic()
            if key != self.last_native_event:
                self.last_native_event, self.last_native_change = key, now
                return None
            if event["phase"] != "begin" or now - self.last_native_change < 30:
                return None
            hosts = [item["host"] for item in self.gate.record["hosts"] if item["mode"] == self.mode]
            targets = [item for item in processes if item["name"] == "sldworks.exe"]
            if len(hosts) != 1 or not hosts[0]["owned_by_daemon"] or len(targets) != 1:
                return None
            self.sampled = True
            output = self.gate.evidence / (self.mode + "-native-stall.log")
            observation = {"request_id": event["request_id"], "operation": event["operation"],
                           "call": event["call"], "stage": event["stage"], "sequence": event["sequence"],
                           "unix_pid": targets[0]["unix_pid"], "evidence": output.name,
                           "duration_seconds": 2, "interval_ms": 10,
                           "tool_timeout_seconds": SAMPLE_TIMEOUT_SECONDS}
            # sample briefly pauses threads at each observation. A lower rate
            # limits this diagnostic's cost; report generation has its own
            # budget, independent of the CI CAD worker deadline.
            # No debugger, dump, COM call or business-operation retry is used.
            try:
                result = subprocess.run(["/usr/bin/sample", str(targets[0]["unix_pid"]), "2", "10",
                                         "-file", str(output)], stdin=subprocess.DEVNULL,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                        timeout=SAMPLE_TIMEOUT_SECONDS, env={"LC_ALL": "C", "LANG": "C"})
                observation["exit_code"] = result.returncode
            except (OSError, subprocess.SubprocessError) as error:
                # Keep the precise boundary and PID even when profiling fails;
                # never publish an exception message containing private text.
                observation["diagnostic_error"] = type(error).__name__
            observation["evidence_present"] = output.is_file()
            return observation
        except (OSError, ValueError, KeyError, StopIteration, subprocess.SubprocessError) as error:
            # Missing logs/tool failures cannot turn a CAD failure into a pass.
            return {"diagnostic_error": type(error).__name__} if self.sampled else None

    def capture(self):
        record = {"phase": self.gate.record["phase"],
                  "utc_time": datetime.now(timezone.utc).isoformat(),
                  "elapsed_seconds": time.monotonic() - self.started_at}
        try:
            record["load_average"] = list(os.getloadavg())
            record["free_disk_bytes"] = shutil.disk_usage(self.gate.root).free
            result = subprocess.run(["/bin/ps", "-axo", "pid=,pcpu=,time=,rss=,stat=,comm="],
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                    encoding="utf-8", errors="replace", timeout=5,
                                    env={"LC_ALL": "C", "LANG": "C"})
            if result.returncode != 0:
                raise RuntimeError("ps failed")
            record["processes"] = wine_process_metrics(result.stdout, self.gate.app)
            sample = self.sample_stalled_host(record["processes"])
            if sample is not None:
                record["native_stall_sample"] = sample
        except Exception as error:
            # OS/tool failures are diagnostic gaps, not CAD failures. Exception
            # messages, ps stderr and raw command lines must never be published.
            record["diagnostic_error"] = type(error).__name__
        try:
            with (self.gate.evidence / (self.mode + "-host-metrics.log")).open("a", encoding="utf-8") as log:
                log.write(json.dumps(record, ensure_ascii=False, allow_nan=False) + "\n")
        except (OSError, ValueError):
            pass
        # A long shared gate must not look silent in Actions. Publish only
        # existing numeric observations; process presence is not COM health.
        elapsed = record["elapsed_seconds"]
        if self.last_progress_seconds is None or elapsed - self.last_progress_seconds >= 60:
            hosts = [item for item in record.get("processes", []) if item["name"] == "sldworks.exe"]
            progress = {"event": "macsw.runtime-progress", "phase": record["phase"],
                        "elapsed_seconds": round(elapsed), "observed_sw_processes": len(hosts),
                        "sw_cpu_percent": sum(item["cpu_percent"] for item in hosts)}
            try:
                print(json.dumps(progress, allow_nan=False), flush=True)
                self.last_progress_seconds = elapsed
            except (OSError, ValueError):
                pass

    def observe(self):
        self.capture()
        while not self.stopped.wait(self.interval):
            self.capture()

    def __enter__(self):
        try:
            self.thread.start()
            self.started = True
        except RuntimeError:
            pass
        return self

    def __exit__(self, *exception):
        self.stopped.set()
        if self.started:
            self.thread.join(timeout=SAMPLE_TIMEOUT_SECONDS + 6)
        return False


def ci_root():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("GitHub Actions runner required")
    return Path(os.environ["RUNNER_TEMP"]).resolve() / "MacSW-runtime"


def remove_private_inputs(root):
    if root != ci_root():
        raise RuntimeError("Refusing cleanup outside the isolated CI root")
    for name in ("private", "app-support", "MacSW.app", "base-cache"):
        target = root / name
        if target.is_symlink():
            target.unlink()
        elif target.exists():
            shutil.rmtree(target)


def cleanup_runtime(root):
    if root != ci_root():
        raise RuntimeError("Refusing cleanup outside the isolated CI root")
    helper = root / "MacSW.app/Contents/MacOS/MacSWCI"
    error = None
    try:
        if helper.is_file():
            result = subprocess.run([str(helper), "cleanup"], stdin=subprocess.DEVNULL,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90)
            if result.returncode != 0:
                error = "CI Wine cleanup exited with code " + str(result.returncode)
    except (OSError, subprocess.TimeoutExpired):
        error = "CI Wine cleanup failed or exceeded its deadline"
    finally:
        try:
            result = subprocess.run([sys.executable, str(PROJECT / "scripts/ci/mount-install.py"), "--cleanup"],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90)
            if result.returncode != 0:
                error = error or "CI media mount cleanup failed"
        except (OSError, subprocess.TimeoutExpired):
            error = error or "CI media mount cleanup exceeded its deadline"
        # Still erase private fixtures/binaries if process cleanup failed. The
        # hosted VM's disposal is the final boundary for surviving processes.
        remove_private_inputs(root)
    if error:
        raise RuntimeError(error)


def shared_gates():
    scripts = [PROJECT / "Dependencies/SWCLI/scripts/ci" / name for name in SHARED_GATES]
    missing = [script.name for script in scripts if not script.is_file()]
    if missing:
        raise RuntimeError("Pinned SWCLI lacks shared CI gates: " + ", ".join(missing)
                           + ". Integrate the upstream scripts and update the pinned commit; do not substitute local tests.")
    return scripts


def text_output(value):
    return value.decode("utf-8", errors="replace") if isinstance(value, bytes) else (value or "")


def snapshot_output(output):
    """Read only existing bytes, without moving an inherited writer's offset."""
    size = os.fstat(output.fileno()).st_size
    chunks, offset = [], 0
    while offset < size:
        chunk = os.pread(output.fileno(), min(size - offset, 1024 * 1024), offset)
        if not chunk:
            break
        chunks.append(chunk)
        offset += len(chunk)
    return text_output(b"".join(chunks)).replace("\r\n", "\n").replace("\r", "\n")


class RuntimeGate:
    def __init__(self, app, evidence):
        self.root = ci_root()
        if app.resolve() != self.root / "MacSW.app" or evidence.resolve() != self.root / "evidence":
            raise RuntimeError("Only the isolated CI App and evidence paths are allowed")
        self.app = app
        self.evidence = evidence
        evidence.mkdir(parents=True, exist_ok=True)
        self.record_path = evidence / "runtime.json"
        if self.record_path.exists():
            raise RuntimeError("Refusing to overwrite previous evidence")
        self.prefix = self.root / "app-support/bottle"
        self.cli = app / "Contents/MacOS/sw-cli"
        self.helper = app / "Contents/MacOS/MacSWCI"
        self.runtime_helper = app / "Contents/MacOS/MacSWCIRuntime"
        self.path_helper = app / "Contents/Resources/SWCLI/bin/swcli-path"
        self.record = {"completed": False, "phase": "initializing", "commands": [], "hosts": [],
                       "host_observations": [], "host_acquisitions": [], "swcli_deployments": [],
                       "budgets_seconds": {"request": REQUEST_TIMEOUT_SECONDS,
                                           "startup": STARTUP_TIMEOUT_SECONDS,
                                           "startup_outer": STARTUP_TIMEOUT_SECONDS + 30,
                                           "shared_gates": dict(SHARED_GATE_TIMEOUT_SECONDS),
                                           "native_sample_tool": SAMPLE_TIMEOUT_SECONDS}}
        self.env = dict(os.environ, MACSW_WINEPREFIX=str(self.prefix), WINEPREFIX=str(self.prefix),
                        SWCLI_ENDPOINT="127.0.0.1:18495", PYTHONDONTWRITEBYTECODE="1",
                        # OLE trace emits millions of GUID/string events during
                        # cold startup and can distort its timing. Keep
                        # errors/warnings, exceptions and module-load evidence.
                        # Driver-level formats/bindings distinguish hosted
                        # CloseDoc graphics failures from the passing local
                        # host. No per-GL-call trace or behavioral workaround.
                        WINEDEBUG="-all,err+ole,warn+ole,+seh,+loaddll,+timestamp,+wgl",
                        # Flushed SWCLI call boundaries survive an owned-worker
                        # deadline; no retry or change to shared CAD assertions.
                        SWCLI_TRACE_NATIVE_CALLS="1",
                        WINE_SOLIDWORKS_STARTUP_TIMEOUT="240")
        for secret in ("SW_SERIAL_SOLIDWORKS", "RCLONE_CONFIG_B64"):
            self.env.pop(secret, None)
        self.cwd = self.prefix / "drive_c/MacSW/CI"
        self.cwd.mkdir(parents=True, exist_ok=True)
        temporary = self.cwd / "tmp"
        temporary.mkdir(exist_ok=True)
        self.env["TMPDIR"] = str(temporary) + "/"
        # Give the isolated App a real, dedicated Wine drive. Existing C: remains
        # preferred for native models; no Z: root mapping is assumed by this adapter.
        mapping = self.prefix / "dosdevices/m:"
        if mapping.exists() or mapping.is_symlink():
            raise RuntimeError("CI M: mapping already exists; refusing to replace it")
        mapping.symlink_to(self.root, target_is_directory=True)
        self.foreground = None
        self.log = None
        self.checkpoint()

    def checkpoint(self):
        staging = self.record_path.with_suffix(".tmp")
        staging.write_text(json.dumps(self.record, ensure_ascii=False, allow_nan=False, indent=2) + "\n")
        staging.replace(self.record_path)

    def phase(self, name):
        self.record["phase"] = name
        self.checkpoint()
        print("MacSW runtime gate: " + name, flush=True)

    def command(self, arguments, *, timeout=300):
        started = time.monotonic()
        entry = {"arguments": list(map(str, arguments)), "completed": False,
                 "timeout_seconds": timeout}
        self.record["commands"].append(entry)
        self.checkpoint()
        # Wine background processes can inherit stdout/stderr after the command
        # exits. Regular files separate its exit deadline from pipe EOF without
        # stopping Wine or treating successful output as a successful exit.
        with tempfile.TemporaryFile(dir=self.cwd / "tmp") as stdout, \
                tempfile.TemporaryFile(dir=self.cwd / "tmp") as stderr:
            process = None
            try:
                process = subprocess.Popen(entry["arguments"], env=self.env, cwd=self.cwd,
                                           stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr)
                entry["unix_pid"] = process.pid
                self.checkpoint()
                entry["exit_code"] = process.wait(timeout=timeout)
                entry["completed"] = True
            except subprocess.TimeoutExpired:
                entry["error"] = "Outer command deadline exceeded"
                entry["running_at_timeout"] = process.poll() is None
                if entry["running_at_timeout"]:
                    process.kill()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        entry["cleanup_error"] = "Command did not exit after termination"
                entry["exit_code"] = process.returncode
                raise
            finally:
                # Snapshot a bounded byte count; descendants may still append.
                # The anonymous files are private and never uploaded directly.
                for name, output in (("stdout", stdout), ("stderr", stderr)):
                    entry[name] = snapshot_output(output)
                entry["duration_seconds"] = time.monotonic() - started
                self.checkpoint()
        if entry["exit_code"] != 0:
            raise RuntimeError("Command failed; see runtime.json: " + str(arguments[0]))
        return entry["stdout"]

    def windows_path(self, path):
        return self.command([self.path_helper, path]).strip()

    def host(self):
        from swcli.daemon.client import call_daemon
        response = call_daemon("daemon.health", endpoint=self.env["SWCLI_ENDPOINT"],
                               timeout_seconds=2, connect_timeout_seconds=0.25)
        if not response.get("success") or not response["result"]["host_connected"]:
            raise RuntimeError("COM host is not ready")
        return response["result"]["host"]

    def same_host(self, expected):
        observed = self.host()
        self.record["host_observations"].append({"phase": self.record["phase"], "host": observed})
        self.checkpoint()
        if observed != expected:
            raise RuntimeError("COM host identity/mode changed between shared gates")

    def start(self, mode):
        self.phase(mode + ".prepare")
        self.command([self.runtime_helper, "prepare", mode])
        deployment = verify_swcli_deployment(self.app, self.prefix)
        self.record["swcli_deployments"].append(dict(deployment, mode=mode))
        self.checkpoint()
        self.command([self.helper, "prepare"])
        self.command([self.runtime_helper, "inspect", mode])
        self.phase(mode + ".startup")
        self.log = (self.evidence / (mode + "-daemon.log")).open("w")
        flags = ["--visible"] if mode == "visible" else []
        self.foreground = subprocess.Popen(
            [str(self.cli), "daemon", "serve", "--startup-timeout", str(STARTUP_TIMEOUT_SECONDS), *flags],
            env=self.env, cwd=self.cwd, stdin=subprocess.DEVNULL, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + STARTUP_TIMEOUT_SECONDS + 30
        while True:
            if self.foreground.poll() is not None:
                raise RuntimeError("swclid exited during startup; see daemon log")
            try:
                host = self.host()
                break
            except (OSError, RuntimeError):
                if time.monotonic() >= deadline:
                    raise RuntimeError("swclid startup deadline exceeded")
                time.sleep(0.3)
        if (host["platform"] != "macos-wine" or not host["owned_by_daemon"]
                or host["shared_interactive"] or host["visible"] != (mode == "visible")):
            raise RuntimeError("Unexpected CI COM host platform/ownership/visibility")
        self.record["hosts"].append({"mode": mode, "host": host})
        self.collect_startup_evidence()
        self.checkpoint()
        return host

    def collect_startup_evidence(self):
        acquisitions = []
        for mode in ("visible", "hidden"):
            log = self.evidence / (mode + "-daemon.log")
            if not log.is_file():
                continue
            with log.open(encoding="utf-8", errors="replace") as stream:
                for line in stream:
                    if not line.startswith("{"):
                        continue
                    try:
                        event = json.loads(line)
                    except ValueError:
                        continue
                    if (event.get("action") == "daemon.startup" and event.get("ok") is True
                            and event.get("phase") == "host-acquired" and isinstance(event.get("host"), dict)):
                        acquisitions.append({"mode": mode, "host": event["host"]})
        # Acquisition is useful failure evidence but does not prove readiness.
        self.record["host_acquisitions"] = acquisitions

    def stop(self):
        self.command([self.cli, "daemon", "stop", "--json"])
        if self.foreground is not None:
            if self.foreground.wait(timeout=90) != 0:
                raise RuntimeError("swclid shutdown failed")
            self.foreground = None
        if self.log:
            self.log.close()
            self.log = None
        # Only between completed mode runs, never between the two shared gates.
        self.command([self.helper, "cleanup"])

    def collect_evidence(self, mode):
        source = self.cwd / mode
        if source.exists():
            for artifact in source.rglob("*"):
                if not artifact.is_file() or artifact.suffix != ".json":
                    continue
                destination = self.evidence / mode / artifact.relative_to(source)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(artifact, destination)

    def run(self):
        scripts = shared_gates()
        self.verify_bitmap_driver()
        for mode in ("visible", "hidden"):
            host = self.start(mode)
            try:
                for script, name in zip(scripts, ("modeling", "driving")):
                    self.phase(mode + "." + name)
                    output = self.cwd / mode / name
                    output.mkdir(parents=True, exist_ok=True)
                    # Both namespaces must refer to the SAME physical directory:
                    # the shared modeling gate checks the locally saved artifact.
                    self.same_host(host)
                    arguments = [sys.executable, script, "--output-dir", output,
                                 "--host-output-dir", self.windows_path(output),
                                 "--cli-command", self.cli, "--endpoint", self.env["SWCLI_ENDPOINT"],
                                 "--request-timeout", str(REQUEST_TIMEOUT_SECONDS)]
                    if name == "driving":
                        arguments += ["--after-modeling", self.cwd / mode / "modeling/modeling.json"]
                    with HostMetrics(self, mode):
                        self.command(arguments, timeout=SHARED_GATE_TIMEOUT_SECONDS[name])
                    self.same_host(host)
            finally:
                self.collect_evidence(mode)
            self.stop()
        self.record["completed"] = True
        self.phase("completed")

    def verify_bitmap_driver(self):
        self.phase("bitmap-driver")
        probe = self.app / "Contents/MacOS/check_bitmap_opengl.exe"
        if not probe.is_file():
            raise RuntimeError("CI-only native bitmap probe is missing")
        self.inspect_cgl_renderers()
        loader = self.app / "Contents/Frameworks/wine/bin/wineloader"
        self.env["WINELOADER"] = str(loader)
        self.env["WINESERVER"] = str(self.app / "Contents/Frameworks/wine/bin/wineserver")
        output = self.command([loader, self.windows_path(probe)], timeout=60)
        records = [json.loads(line) for line in output.splitlines() if line.startswith("{")]
        expected = {(bpp, width, top_down) for bpp in (24, 32) for width in (7, 8) for top_down in (False, True)}
        actual = {(item.get("bpp"), item.get("width"), item.get("top_down")) for item in records}
        if (len(records) != 8 or actual != expected or
                any(item.get("success") is not True or item.get("stage") != "complete" or
                    item.get("red_pixels") != item["width"] * 8 or item.get("gl_error") != 0 or
                    item.get("depth", 0) < 24 or item.get("stencil", 0) < 8 for item in records)):
            raise RuntimeError("Native bitmap pixel/format/context verification failed")
        self.record["bitmap_driver"] = records
        self.checkpoint()

    def inspect_cgl_renderers(self):
        # Observe both native and Rosetta frameworks before Wine initialization.
        # Unsupported CGL modes do not pass, skip or replace the bitmap gate.
        self.record["cgl_renderers"] = {}
        for architecture in ("arm64", "x86_64"):
            probe = self.app / "Contents/MacOS" / ("check_cgl_" + architecture)
            if not probe.is_file():
                raise RuntimeError("CI-only CGL renderer probe is missing: " + architecture)
            output = self.command([probe], timeout=30)
            self.record["cgl_renderers"][architecture] = [json.loads(line) for line in output.splitlines()]
            self.checkpoint()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--cleanup-private", action="store_true")
    parser.add_argument("--check-shared-gates", action="store_true")
    args = parser.parse_args()
    if args.check_shared_gates:
        shared_gates()
        return
    if args.cleanup_private:
        cleanup_runtime(ci_root())
        return
    if args.app is None or args.evidence is None:
        raise RuntimeError("--app and --evidence are required")
    gate = RuntimeGate(args.app, args.evidence)
    try:
        gate.run()
    except Exception as error:
        gate.record["error"] = {"type": type(error).__name__, "message": str(error)}
        try:
            gate.collect_startup_evidence()
        except OSError:
            gate.record["startup_evidence_error"] = "Unable to read daemon startup log"
        gate.checkpoint()
        raise
    finally:
        if gate.log:
            gate.log.close()


if __name__ == "__main__":
    main()
