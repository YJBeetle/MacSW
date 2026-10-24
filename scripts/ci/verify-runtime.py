"""Run lightweight visible smoke, or opt-in hidden CAD diagnostics.

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
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

PROJECT = Path(__file__).resolve().parents[2]
SHARED_GATES = ("verify-modeling.py", "verify-driving-dimensions.py", "verify-toolbox.py")
SETS_GATE = "verify-runtime-sets.py"
VISIBLE_GATE = "verify-visible.py"
VISIBLE_TIMEOUT_SECONDS = 900
SETS_TIMEOUT_SECONDS = {"core": 13800, "full": 19200}


def shared_plan(suite, diagnostic_set=None):
    sys.path.insert(0, str(PROJECT / "Dependencies/SWCLI/scripts/ci"))
    from gate_support.runtime_plan import runtime_plan, diagnostic_plan
    return diagnostic_plan(suite, diagnostic_set) if diagnostic_set else runtime_plan(suite)


def installed_drawing_template(script, prefix):
    sys.path.insert(0, str(script.parent))
    from gate_support.drawing_template import drawing_template
    explicit = os.environ.get("SWCLI_DRAWING_TEMPLATE")
    if not explicit:
        # Wine has the official base GB template, not Windows' first-run gb_a4 copy.
        matches = [path for path in prefix.glob("drive_c/Program Files/*/data/templates/gb.drwdot")
                   if path.is_file() and not path.is_symlink()
                   and path.resolve().is_relative_to(prefix.resolve())]
        if len(matches) != 1:
            raise RuntimeError("Installed GB drawing template is missing or ambiguous; set SWCLI_DRAWING_TEMPLATE")
        explicit = matches[0]
    return drawing_template(prefix / "drive_c/ProgramData", explicit)


def modeling_samples(prefix, *, part_only=False):
    """Locate installed host fixtures; CAD assertions remain in SWCLI."""
    patterns = (
        "drive_c/users/Public/Documents/SOLIDWORKS/SOLIDWORKS */samples/learn/Paper Airplane.SLDPRT",
        "drive_c/Program Files/*/sldBenchmarking/Macro/Mold/bezel moldbase.sldasm",
    )
    if part_only:
        patterns = patterns[:1]
    samples = []
    for pattern in patterns:
        matches = [path for path in prefix.glob(pattern) if path.is_file() and not path.is_symlink()
                   and path.resolve().is_relative_to(prefix.resolve()) and path.stat().st_size > 0]
        if len(matches) != 1:
            raise RuntimeError("Installed modeling sample is missing or ambiguous: " + pattern)
        samples.append(matches[0])
    return tuple(samples)

# Hosted software rendering is slower than local hardware. These are CI-only
# limits; the shared assertions and SWCLI product defaults remain unchanged.
REQUEST_TIMEOUT_SECONDS = 600
STARTUP_TIMEOUT_SECONDS = 300
# The expanded gate includes native assembly save/reopen and sample exports.
# A 600-second request can now complete, but the accumulated software-renderer
# work still exceeds the former one-hour modeling limit.
SHARED_GATE_TIMEOUT_SECONDS = {"modeling": 5400, "driving": 7200, "toolbox": 600}
FULL_SHARED_GATE_TIMEOUT_SECONDS = {**SHARED_GATE_TIMEOUT_SECONDS, "driving": 12600}
SAMPLE_TIMEOUT_SECONDS = 30
NATIVE_SAMPLE_INTERVAL_SECONDS = 60
NATIVE_SAMPLE_LIMIT_PER_MODE = 140
SYSTEM_METRICS_TIMEOUT_SECONDS = 2
SCREENSHOT_TIMEOUT_SECONDS = 20
SCREENSHOT_INTERVAL_SECONDS = 300
SCREENSHOT_LIMIT_PER_MODE = 64


def system_memory_metrics():
    """Numeric, read-only OS observations; never retain raw tool output."""
    record = {}
    commands = {
        "vm_stat": ["/usr/bin/vm_stat"],
        "swap": ["/usr/sbin/sysctl", "-n", "vm.swapusage"],
        "pressure": ["/usr/bin/memory_pressure", "-Q"],
    }
    for name, command in commands.items():
        try:
            result = subprocess.run(command, stdin=subprocess.DEVNULL, capture_output=True,
                                    text=True, encoding="utf-8", errors="replace",
                                    timeout=SYSTEM_METRICS_TIMEOUT_SECONDS,
                                    env={"LC_ALL": "C", "LANG": "C"})
            if result.returncode != 0:
                raise ValueError("tool failed")
            if name == "vm_stat":
                page = re.search(r"page size of (\d+) bytes", result.stdout)
                if not page or int(page[1]) <= 0:
                    raise ValueError("page size unavailable")
                counters = {}
                for label in ("Pages free", "Pages active", "Pages inactive", "Pages speculative",
                              "Pages wired down", "Pages purgeable", "Pages occupied by compressor",
                              "Compressions", "Decompressions", "Pageins", "Pageouts", "Swapins", "Swapouts"):
                    match = re.search(r"^" + re.escape(label) + r":\s*(\d+)\.?\s*$",
                                      result.stdout, re.MULTILINE)
                    if match:
                        counters[label.lower().replace(" ", "_")] = int(match[1])
                if not counters:
                    raise ValueError("VM counters unavailable")
                record["vm_stat"] = {"page_size_bytes": int(page[1]), "counters": counters}
            elif name == "swap":
                amounts = {}
                for label in ("total", "used", "free"):
                    match = re.search(r"\b" + label + r"\s*=\s*(\d+(?:\.\d+)?)([KMGT])\b", result.stdout)
                    if not match:
                        raise ValueError("swap amount unavailable")
                    value = float(match[1]) * 1024 ** ("KMGT".index(match[2]) + 1)
                    if not math.isfinite(value):
                        raise ValueError("invalid swap amount")
                    amounts[label + "_bytes"] = round(value)
                record["swap"] = amounts
            else:
                match = re.search(r"System-wide memory free percentage:\s*(\d+)%", result.stdout)
                if not match or not 0 <= int(match[1]) <= 100:
                    raise ValueError("memory availability unavailable")
                record["available_percent"] = int(match[1])
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            record.setdefault("diagnostic_errors", {})[name] = type(error).__name__
    return record


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
    resources = app / "Contents/Resources/SWCLI"
    source = runtime_inventory(resources / "runtime/Python311")
    manifest = runtime_record(resources / "runtime-manifest.json", "App SWCLI runtime manifest")
    if (not isinstance(manifest, dict)
            or set(manifest) != {"format", "version", "source_commit", "files"}
            or type(manifest["format"]) is not int or manifest["format"] != 1
            or any(not isinstance(manifest[key], str) or not manifest[key].strip()
                   for key in ("version", "source_commit"))
            or manifest["files"] != source):
        raise RuntimeError("App SWCLI runtime manifest differs from its payload")
    target = prefix / "drive_c/MacSW/Python311"
    installed = runtime_inventory(target)
    marker = ".macsw-runtime.json"
    receipt = runtime_record(target / marker, "Installed SWCLI deployment receipt")
    if (not isinstance(receipt, dict) or set(receipt) != set(manifest)
            or type(receipt["format"]) is not int or receipt["format"] != 1
            or receipt != manifest):
        raise RuntimeError("Installed SWCLI deployment receipt differs from this run's App")
    # Only this independently verified metadata is not an App payload file.
    # All other files, including unknown entries and bytecode caches, remain
    # subject to exact comparison; a missing/invalid receipt never passes.
    installed.pop(marker)
    if installed != source:
        raise RuntimeError("Installed SWCLI runtime differs from this run's App")
    digest = hashlib.sha256(json.dumps(source, sort_keys=True).encode()).hexdigest()
    return {"verified": True, "receipt_verified": True, "files": len(source), "sha256": digest,
            "version": manifest["version"], "source_commit": manifest["source_commit"]}


def runtime_record(path, label):
    if path.is_symlink() or not path.is_file():
        raise RuntimeError(label + " is missing or not a regular file")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, ValueError) as error:
        raise RuntimeError(label + " is invalid") from error


def wine_process_metrics(output, app):
    """Keep numeric metrics of known Wine processes, never their arguments."""
    processes = []
    server = app / "Contents/Frameworks/wine/bin/wineserver"
    server_paths = {str(server), str(server.resolve())}
    for line in output.splitlines():
        fields = line.split(None, 5)
        if len(fields) != 6:
            continue
        command = fields[5]
        # On this fresh, isolated CI VM these Windows paths are our Wine host.
        # Unix Python/runner processes and arbitrary command lines are excluded.
        name = command.rsplit("\\", 1)[-1].lower()
        if command in server_paths:
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
        self.last_native_payload = None
        self.native_log_identity = None
        self.native_log_size = 0
        self.last_native_change = time.monotonic()
        self.last_system_metrics_seconds = None
        self.last_screenshot_seconds = 0
        self.last_set = None
        # Shared across all three gates in this mode, so a new metrics context
        # cannot overwrite reports or reset the diagnostic rate/size limits.
        self.sample_state = gate.native_sample_states.setdefault(
            mode, {"count": 0, "last_at": None})

    def sample_stalled_host(self, processes):
        """Repeat bounded samples for stalled AND progressing slow requests."""
        if self.sample_state["count"] >= NATIVE_SAMPLE_LIMIT_PER_MODE or self.stopped.is_set():
            return None
        path = self.gate.evidence / (self.mode + "-daemon.log")
        try:
            # Do not consume/move the daemon's writer offset or copy huge logs.
            with path.open("rb") as source:
                stat = os.fstat(source.fileno())
                identity = (stat.st_dev, stat.st_ino)
                if identity != self.native_log_identity or stat.st_size < self.native_log_size:
                    self.last_native_payload = None
                    self.last_native_event = None
                self.native_log_identity, self.native_log_size = identity, stat.st_size
                source.seek(max(0, stat.st_size - 128 * 1024))
                lines = source.read().decode("utf-8", errors="replace").splitlines()
            event = next((json.loads(line) for line in reversed(lines)
                          if line.startswith('{"event": "swcli.native-call"')), None)
            boundary_source = "log-tail"
            if event is None:
                # Wine diagnostics can push a blocked call out of the bounded
                # tail. Absence of a new boundary does not mean completion.
                # Retain the last observation only for this same growing log;
                # it is diagnostic context, never a health/gate decision.
                event = self.last_native_payload
                boundary_source = "cached-observation"
            else:
                self.last_native_payload = event
            if event is None:
                return None
            if event["phase"] not in ("begin", "end"):
                return None
            if event["stage"] == "operation" and event["phase"] == "end":
                return None  # The request has already finished, not stalled.
            key = (event["worker_pid"], event["request_id"], event["sequence"], event["phase"])
            now = time.monotonic()
            if key != self.last_native_event:
                self.last_native_event, self.last_native_change = key, now
            stalled = event["phase"] == "begin" and now - self.last_native_change >= 30
            previous = self.sample_state["last_at"]
            periodic = now - (self.started_at if previous is None else previous) >= NATIVE_SAMPLE_INTERVAL_SECONDS
            # A completed, unchanged boundary is idle, not a slow request.
            active = event["phase"] == "begin" or now - self.last_native_change < 30
            if not active or not (stalled or periodic):
                return None
            if previous is not None and now - previous < NATIVE_SAMPLE_INTERVAL_SECONDS:
                return None
            owned = self.gate.observed_host(self.mode)
            hosts = [owned["host"]] if owned else []
            targets = [item for item in processes if item["name"] == "sldworks.exe"]
            if len(hosts) != 1 or not hosts[0]["owned_by_daemon"] or len(targets) != 1:
                return None
            self.sample_state["count"] += 1
            self.sample_state["last_at"] = now
            output = self.gate.evidence / (self.mode + "-native-sample-"
                                          + str(self.sample_state["count"]).zfill(3) + ".log")
            observation = {"request_id": event["request_id"], "operation": event["operation"],
                           "call": event["call"], "stage": event["stage"], "sequence": event["sequence"],
                           "boundary_phase": event["phase"], "reason": "stalled" if stalled else "periodic",
                           "boundary_source": boundary_source,
                           "observed_utc_time": datetime.now(timezone.utc).isoformat(),
                           "phase": self.gate.record["phase"], "sample_index": self.sample_state["count"],
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
            return {"diagnostic_error": type(error).__name__} if self.sample_state["count"] else None

    def capture(self):
        record = {"phase": self.gate.record["phase"],
                  "utc_time": datetime.now(timezone.utc).isoformat(),
                  "elapsed_seconds": time.monotonic() - self.started_at}
        try:
            record["load_average"] = list(os.getloadavg())
            record["free_disk_bytes"] = shutil.disk_usage(self.gate.root).free
            owned = self.gate.observed_host(self.mode)
            if owned and "test_set" in owned:
                record["test_set"] = owned["test_set"]
                if owned["test_set"] != self.last_set:
                    self.last_set = owned["test_set"]
                    self.gate.capture_sw_window(self.mode, "start-" + self.last_set)
            result = subprocess.run(["/bin/ps", "-axo", "pid=,pcpu=,time=,rss=,stat=,comm="],
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                    encoding="utf-8", errors="replace", timeout=5,
                                    env={"LC_ALL": "C", "LANG": "C"})
            if result.returncode != 0:
                raise RuntimeError("ps failed")
            record["processes"] = wine_process_metrics(result.stdout, self.gate.app)
            if (self.last_system_metrics_seconds is None
                    or record["elapsed_seconds"] - self.last_system_metrics_seconds >= 60):
                record["system_memory"] = system_memory_metrics()
                self.last_system_metrics_seconds = record["elapsed_seconds"]
            sample = self.sample_stalled_host(record["processes"])
            if sample is not None:
                record["native_sample"] = sample
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
            elapsed = time.monotonic() - self.started_at
            if elapsed - self.last_screenshot_seconds >= SCREENSHOT_INTERVAL_SECONDS:
                self.last_screenshot_seconds = elapsed
                self.gate.capture_sw_window(self.mode, "periodic-" + str(round(elapsed)).zfill(5))

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
            self.thread.join(timeout=SAMPLE_TIMEOUT_SECONDS + 6 + 3 * SYSTEM_METRICS_TIMEOUT_SECONDS
                             + SCREENSHOT_TIMEOUT_SECONDS)
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


def shared_sets_gate():
    script = PROJECT / "Dependencies/SWCLI/scripts/ci" / SETS_GATE
    if not script.is_file():
        raise RuntimeError("Pinned SWCLI lacks the shared isolated functional sets gate")
    return script


def shared_visible_gate():
    script = PROJECT / "Dependencies/SWCLI/scripts/ci" / VISIBLE_GATE
    if not script.is_file():
        raise RuntimeError("Pinned SWCLI lacks the independent visible smoke entrypoint")
    return script


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


class SharedGateProgress:
    """Timestamp allowlisted stdout progress without pipes or CAD decisions.

    These are observation times (0.5s polling), not native-call durations. No
    command arguments, result payloads or stderr are echoed into Actions.
    """

    PATTERN = re.compile(
        r"(Modeling gate|Driving-dimension gate|Toolbox gate|Runtime sets): ([a-z][a-z0-9_. -]{0,95})"
    )

    def __init__(self, output, evidence, phase, started):
        self.output = output
        self.evidence = evidence
        self.phase = phase
        self.started = started
        self.previous = None
        self.offset = 0
        self.pending = b""
        self.stopped = threading.Event()
        self.thread = threading.Thread(target=self.observe, daemon=True)
        self.started_thread = False

    def capture(self):
        # pread leaves the inherited file offset untouched; never wait for EOF.
        chunk = os.pread(self.output.fileno(), 65536, self.offset)
        self.offset += len(chunk)
        lines = (self.pending + chunk).split(b"\n")
        self.pending = lines.pop()
        # Discard overlong untrusted lines, including fragments spanning reads.
        if len(self.pending) > 2048:
            self.pending = b"!"  # Cannot match an allowlisted progress prefix.
        for line in lines:
            if len(line) > 2048:
                continue
            match = self.PATTERN.fullmatch(line.decode("utf-8", errors="replace").rstrip("\r"))
            if not match:
                continue
            now = time.monotonic()
            record = {
                "event": "macsw.shared-step-progress",
                "phase": self.phase,
                "gate": match[1],
                "stage": match[2],
                "observed_utc_time": datetime.now(timezone.utc).isoformat(),
                "elapsed_seconds": round(now - self.started, 3),
                "since_previous_progress_seconds": (
                    None if self.previous is None else round(now - self.previous, 3)
                ),
                "timing_basis": "stdout-observed",
            }
            self.previous = now
            payload = json.dumps(record, allow_nan=False)
            with self.evidence.open("a", encoding="utf-8") as stream:
                stream.write(payload + "\n")
            print(payload, flush=True)
        return len(chunk)

    def observe(self):
        while not self.stopped.is_set():
            try:
                self.capture()
            except (OSError, ValueError):
                pass  # Diagnostic failure must not change the test outcome.
            self.stopped.wait(0.5)

    def start(self):
        try:
            self.thread.start()
            self.started_thread = True
        except RuntimeError:
            pass

    def stop(self):
        self.stopped.set()
        if self.started_thread:
            self.thread.join(timeout=2)
            if self.thread.is_alive():
                return  # Do not read/print concurrently with a stuck observer.
        try:
            # Drain only bytes already written; descendants may still be alive.
            size = os.fstat(self.output.fileno()).st_size
            while self.offset < size:
                if not self.capture():
                    break
        except (OSError, ValueError):
            pass


class RuntimeGate:
    def __init__(self, app, evidence, suite="full", renderer="auto", mode=None,
                 profile="visible-smoke", diagnostic_set=None, diagnostic_visible=False):
        # Retain the explicit suite/mode library interface for existing callers.
        # CLI/workflows expose only the two named profiles below.
        if profile not in (None, "visible-smoke", "hidden-full"):
            raise ValueError("Unknown runtime profile")
        self.profile = profile
        if diagnostic_set and (profile != "hidden-full" or diagnostic_set not in
                               {"drawing-save", "drawing-save-as", "drawings", "drawing-copy-first", "drawing-copy-reopen", "drawing-reopen-no-inspect"}):
            raise ValueError("Diagnostic set requires hidden-full and a supported drawing set")
        self.diagnostic_set = diagnostic_set
        if diagnostic_visible and not diagnostic_set:
            raise ValueError("Visible diagnostic requires a selected diagnostic set")
        if profile is not None:
            selected_mode = "hidden" if profile == "hidden-full" and not diagnostic_visible else "visible"
            if mode is not None and mode != selected_mode:
                raise ValueError("Mode is not supported by the selected profile")
            suite = "full" if profile == "hidden-full" else "core"
            mode = selected_mode
        if suite not in ("core", "full"):
            raise ValueError("Unknown runtime suite")
        self.suite = suite
        self.modes = ("visible", "hidden") if suite == "full" else ("visible",)
        if mode is not None:
            if mode not in self.modes:
                raise ValueError("Mode is not supported by the selected suite")
            self.modes = (mode,)
        self.timeouts = dict(FULL_SHARED_GATE_TIMEOUT_SECONDS if suite == "full"
                             else SHARED_GATE_TIMEOUT_SECONDS)
        if renderer not in ("auto", "software"):
            raise ValueError("Unknown renderer selection")
        self.renderer = renderer
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
        self.native_sample_states = {}
        self.record = {"completed": False, "phase": "initializing", "commands": [], "hosts": [],
                       "host_observations": [], "host_acquisitions": [], "swcli_deployments": [],
                       "screenshots": [],
                       "profile": profile,
                       "diagnostic_set": diagnostic_set,
                       "diagnostic_visible": diagnostic_visible,
                       "full_acceptance_eligible": diagnostic_set is None and profile == "hidden-full",
                       "suite": None if profile == "visible-smoke" else suite,
                       "coverage": ({"visible": "read-only-open-inspect-close"}
                                    if profile == "visible-smoke" else {mode: suite for mode in self.modes}),
                       "renderer_request": renderer,
                       "budgets_seconds": {"request": REQUEST_TIMEOUT_SECONDS,
                                           "startup": STARTUP_TIMEOUT_SECONDS,
                                           "startup_outer": STARTUP_TIMEOUT_SECONDS + 30,
                                           "shared_gates": {} if profile == "visible-smoke" else dict(self.timeouts),
                                           "native_sample_tool": SAMPLE_TIMEOUT_SECONDS,
                                           "native_sample_interval": NATIVE_SAMPLE_INTERVAL_SECONDS,
                                           "native_sample_limit_per_mode": NATIVE_SAMPLE_LIMIT_PER_MODE,
                                           "system_metrics_tool": SYSTEM_METRICS_TIMEOUT_SECONDS,
                                           "screenshot_tool": SCREENSHOT_TIMEOUT_SECONDS,
                                           "screenshot_interval": SCREENSHOT_INTERVAL_SECONDS,
                                           "screenshot_limit_per_mode": SCREENSHOT_LIMIT_PER_MODE}}
        self.env = dict(os.environ, MACSW_WINEPREFIX=str(self.prefix), WINEPREFIX=str(self.prefix),
                        MACSW_OPENGL_RENDERER=renderer,
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
                 "timeout_seconds": timeout,
                 "started_utc_time": datetime.now(timezone.utc).isoformat()}
        self.record["commands"].append(entry)
        self.checkpoint()
        # Wine background processes can inherit stdout/stderr after the command
        # exits. Regular files separate its exit deadline from pipe EOF without
        # stopping Wine or treating successful output as a successful exit.
        with tempfile.TemporaryFile(dir=self.cwd / "tmp") as stdout, \
                tempfile.TemporaryFile(dir=self.cwd / "tmp") as stderr:
            process = None
            progress = None
            if any(Path(str(argument)).name in (*SHARED_GATES, SETS_GATE, VISIBLE_GATE) for argument in arguments):
                progress = SharedGateProgress(
                    stdout, self.evidence / "shared-step-progress.log",
                    self.record["phase"], started,
                )
                progress.start()
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
                if progress is not None:
                    progress.stop()
                # Snapshot a bounded byte count; descendants may still append.
                # The anonymous files are private and never uploaded directly.
                for name, output in (("stdout", stdout), ("stderr", stderr)):
                    entry[name] = snapshot_output(output)
                entry["duration_seconds"] = time.monotonic() - started
                entry["finished_utc_time"] = datetime.now(timezone.utc).isoformat()
                self.checkpoint()
                if progress is not None:
                    print(json.dumps({
                        "event": "macsw.shared-command-end",
                        "phase": self.record["phase"],
                        "finished_utc_time": entry["finished_utc_time"],
                        "duration_seconds": round(entry["duration_seconds"], 3),
                        "completed": entry["completed"],
                        "exit_code": entry.get("exit_code"),
                        "error": entry.get("error"),
                    }), flush=True)
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
        self.prepare(mode)
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

    def prepare(self, mode):
        self.phase(mode + ".prepare")
        self.command([self.runtime_helper, "prepare", mode])
        deployment = verify_swcli_deployment(self.app, self.prefix)
        self.record["swcli_deployments"].append(dict(deployment, mode=mode))
        self.checkpoint()
        self.command([self.helper, "prepare"])
        self.command([self.runtime_helper, "inspect", mode])

    def active_set_host(self, mode):
        path = self.cwd / mode / "runtime-sets/runtime-sets.json"
        if not path.is_file():
            return None
        record = runtime_record(path, "Shared runtime sets")
        active = record.get("active_set")
        matches = [item for item in record.get("sets", []) if item.get("name") == active and "host" in item]
        if len(matches) != 1:
            return None
        return {"mode": mode, "test_set": active, "host": matches[0]["host"]}

    def observed_host(self, mode, allow_finished=False):
        if self.record["phase"] == mode + ".test-sets":
            active = self.active_set_host(mode)
            if active or not allow_finished:
                return active
            path = self.cwd / mode / "runtime-sets/runtime-sets.json"
            if path.is_file():
                sets = runtime_record(path, "Shared runtime sets").get("sets", [])
                if sets and "host" in sets[-1]:
                    return {"mode": mode, "test_set": sets[-1]["name"], "host": sets[-1]["host"]}
            return None
        hosts = [item for item in self.record["hosts"] if item["mode"] == mode]
        return hosts[0] if len(hosts) == 1 else None

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
        # Only between completed mode runs, never between the shared gates.
        self.command([self.helper, "cleanup"])

    def collect_evidence(self, mode):
        source = self.cwd / mode
        if source.exists():
            for artifact in source.rglob("*"):
                if not artifact.is_file() or artifact.suffix not in (".json", ".log"):
                    continue
                destination = self.evidence / mode / artifact.relative_to(source)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(artifact, destination)

    def capture_sw_window(self, mode, reason):
        """Hosted CAD desktop diagnostics; never capture private setup or local desktop."""
        phase = self.record["phase"]
        allowed = {mode + "." + name for name in (*SHARED_GATE_TIMEOUT_SECONDS, "test-sets", "visible-smoke")}
        limit = SCREENSHOT_LIMIT_PER_MODE - (9 if reason.startswith("periodic-") else 0)
        if sum(item.get("mode") == mode for item in self.record["screenshots"]) >= limit:
            return
        observation = {"phase": phase, "mode": mode, "reason": reason,
                       "utc_time": datetime.now(timezone.utc).isoformat()}
        try:
            active = self.observed_host(mode, allow_finished=reason in ("failure", "end"))
            hosts = [active["host"]] if active else []
            if (phase not in allowed or len(hosts) != 1 or not hosts[0]["owned_by_daemon"]
                    or hosts[0]["shared_interactive"]):
                return
            result = subprocess.run(["/bin/ps", "-axo", "pid=,pcpu=,time=,rss=,stat=,comm="],
                                    capture_output=True, text=True, timeout=5)
            targets = [p for p in wine_process_metrics(result.stdout, self.app)
                       if p["name"] == "sldworks.exe"]
            observation["host_present"] = result.returncode == 0 and len(targets) == 1
            if active and "test_set" in active:
                observation["test_set"] = active["test_set"]
            if observation["host_present"]:
                observation["unix_pid"] = targets[0]["unix_pid"]
            directory = self.evidence / "screenshots"
            directory.mkdir(exist_ok=True)
            path = directory / (phase.replace(".", "-") + "-" + reason + ".png")
            capture = subprocess.run([sys.executable, PROJECT / "scripts/ci/capture-sw-window.py",
                                      "--output", path,
                                      "--scope", "desktop"],
                                     capture_output=True, text=True, timeout=SCREENSHOT_TIMEOUT_SECONDS)
            receipt = json.loads(capture.stdout)
            observation.update(receipt)
            if (capture.returncode == 0 and receipt.get("success") is True
                    and receipt.get("source") == "github-hosted-desktop"
                    and receipt.get("display_id") == 1
                    and receipt.get("file") == path.name):
                observation.update(owned_by_daemon=True, shared_interactive=False,
                                   runner_environment="github-hosted",
                                   host_windows_pid=hosts[0]["process_id"])
                path.with_suffix(".json").write_text(json.dumps(observation, indent=2) + "\n")
            elif receipt.get("success") is True:
                raise ValueError("Screenshot receipt does not match the selected host")
        except Exception as error:
            observation.update(success=False, diagnostic_error=type(error).__name__)
        finally:
            if phase in allowed:
                self.record["screenshots"].append(observation)

    def run_continuous(self):
        scripts = shared_gates()
        sample_part, sample_assembly = modeling_samples(self.prefix)
        self.verify_bitmap_driver()
        for mode in self.modes:
            host = self.start(mode)
            try:
                stages = list(zip(scripts, ("modeling", "driving", "toolbox")))
                for script, name in stages:
                    self.phase(mode + "." + name)
                    output = self.cwd / mode / name
                    output.mkdir(parents=True, exist_ok=True)
                    self.same_host(host)
                    self.capture_sw_window(mode, "start")
                    arguments = [sys.executable, script, "--output-dir", output,
                                 "--cli-command", self.cli, "--endpoint", self.env["SWCLI_ENDPOINT"],
                                 "--request-timeout", str(REQUEST_TIMEOUT_SECONDS)]
                    if name == "toolbox":
                        # Toolbox reads official models; its only output is local
                        # JSON evidence. The shared gate resolves the registry and
                        # actual dosdevices mappings in this isolated bottle.
                        arguments += ["--wine-prefix", self.prefix, "--require-toolbox"]
                    else:
                        # Modeling writes CAD files: both namespaces must refer
                        # to the SAME physical directory for artifact checks.
                        arguments += ["--host-output-dir", self.windows_path(output),
                                      "--suite", self.suite]
                    if name == "driving":
                        arguments += ["--after-modeling", self.cwd / mode / "modeling/modeling.json"]
                    elif name == "modeling":
                        arguments += ["--sample-part", self.windows_path(sample_part),
                                      "--sample-assembly", self.windows_path(sample_assembly)]
                    with HostMetrics(self, mode):
                        self.command(arguments, timeout=self.timeouts[name])
                    self.same_host(host)
                    self.capture_sw_window(mode, "end")
            except Exception:
                self.capture_sw_window(mode, "failure")
                raise
            finally:
                self.collect_evidence(mode)
            self.stop()
        self.record["completed"] = True
        self.phase("completed")

    def run(self):
        if self.profile == "visible-smoke":
            self.run_visible()
        else:
            self.run_sets()

    def finish_visible_daemon(self):
        # The shared entrypoint already requested public daemon stop. Its
        # acknowledgment is not sufficient: require normal launcher exit and
        # disappearance of SW on this isolated hosted VM, before forced cleanup.
        if self.foreground is None or self.foreground.wait(timeout=90) != 0:
            raise RuntimeError("Visible swclid did not exit normally")
        self.record["server_exit_code"] = self.foreground.returncode
        self.foreground = None
        if self.log:
            self.log.close()
            self.log = None
        deadline = time.monotonic() + 30
        while True:
            result = subprocess.run(["/bin/ps", "-axo", "pid=,pcpu=,time=,rss=,stat=,comm="],
                                    capture_output=True, text=True, timeout=5,
                                    env={"LC_ALL": "C", "LANG": "C"})
            if result.returncode:
                raise RuntimeError("Cannot verify visible SW process exit")
            if not any(item["name"] == "sldworks.exe"
                       for item in wine_process_metrics(result.stdout, self.app)):
                self.record["host_process_exited"] = True
                return
            if time.monotonic() >= deadline:
                raise RuntimeError("Visible SW survived daemon shutdown")
            time.sleep(0.3)

    def run_visible(self):
        script = shared_visible_gate()
        sample, = modeling_samples(self.prefix, part_only=True)
        self.verify_bitmap_driver()
        host = self.start("visible")
        self.record["session_policy"] = "single-visible-smoke"
        self.record["coverage"] = {"visible": "read-only-open-inspect-close"}
        self.record["budgets_seconds"]["visible_smoke"] = VISIBLE_TIMEOUT_SECONDS
        self.phase("visible.visible-smoke")
        output = self.cwd / "visible/visible-smoke"
        output.mkdir(parents=True, exist_ok=True)
        try:
            with HostMetrics(self, "visible"):
                self.capture_sw_window("visible", "start")
                self.command([sys.executable, script, "--output-dir", output,
                              "--sample-part", self.windows_path(sample), "--cli-command", self.cli,
                              "--endpoint", self.env["SWCLI_ENDPOINT"],
                              "--request-timeout", str(REQUEST_TIMEOUT_SECONDS)], timeout=VISIBLE_TIMEOUT_SECONDS)
            proof = runtime_record(output / "visible.json", "Shared visible smoke")
            if (proof.get("state") != "completed" or proof.get("success") is not True
                    or proof.get("profile") != "visible-open" or proof.get("cleanup_errors") != []
                    or proof.get("request_timeout_seconds") != REQUEST_TIMEOUT_SECONDS
                    or not all(isinstance(proof.get(key), dict)
                               and proof[key].get("process_id") == host["process_id"]
                               and proof[key].get("platform") == "macos-wine"
                               and proof[key].get("visible") is True
                               and proof[key].get("owned_by_daemon") is True
                               and proof[key].get("shared_interactive") is False
                               for key in ("host", "host_after"))):
                raise RuntimeError("Shared visible smoke evidence did not pass")
            self.record["visible_smoke"] = proof
            # Record the effective shared-gate budget, verified above, rather
            # than claiming a limit that was not actually forwarded.
            self.record["budgets_seconds"]["request"] = proof.get("request_timeout_seconds")
            self.finish_visible_daemon()
            self.capture_sw_window("visible", "end")
        except Exception:
            self.capture_sw_window("visible", "failure")
            raise
        finally:
            self.collect_evidence("visible")
        self.record["completed"] = True
        self.phase("completed")

    def run_sets(self):
        script = shared_sets_gate()
        template_arguments = []
        if self.suite == "full":
            template = installed_drawing_template(script, self.prefix)
            template_arguments = ["--drawing-template", self.windows_path(template)]
        sample_part, sample_assembly = modeling_samples(self.prefix)
        sample_drawing = sample_assembly.with_suffix(".slddrw")
        if not sample_drawing.is_file() or sample_drawing.is_symlink():
            raise RuntimeError("Installed official drawing fixture is missing")
        self.verify_bitmap_driver()
        self.prepare(self.modes[0])  # One container/App deployment, not per test set or mode.
        self.record["session_policy"] = "fresh-per-test-set"
        self.record["functional_sets"] = {}
        self.record["budgets_seconds"]["functional_suite"] = SETS_TIMEOUT_SECONDS[self.suite]
        self.record["budgets_seconds"]["test_set"] = 1800
        deadline = time.monotonic() + SETS_TIMEOUT_SECONDS[self.suite]
        plan = shared_plan(self.suite, self.diagnostic_set)
        expected = [item.name for item in plan]
        for mode in self.modes:
            self.phase(mode + ".test-sets")
            output = self.cwd / mode / "runtime-sets"
            output.mkdir(parents=True, exist_ok=True)
            work = self.cwd / "private-drawing-work"
            work.mkdir(exist_ok=True)
            arguments = [sys.executable, script, "--suite", self.suite, "--mode", mode,
                         "--output-dir", output, "--host-output-dir", self.windows_path(output),
                         "--cli-command", self.cli, "--endpoint", self.env["SWCLI_ENDPOINT"],
                         "--request-timeout", str(REQUEST_TIMEOUT_SECONDS), "--startup-timeout", str(STARTUP_TIMEOUT_SECONDS),
                         "--set-timeout", "1800", "--sample-part", self.windows_path(sample_part),
                         "--sample-assembly", self.windows_path(sample_assembly),
                         "--sample-drawing", self.windows_path(sample_drawing), "--sample-drawing-local", sample_drawing,
                         "--fixture-work-dir", work, "--host-fixture-work-dir", self.windows_path(work),
                         "--wine-prefix", self.prefix, "--daemon-log", self.evidence / (mode + "-daemon.log"),
                         *template_arguments]
            if self.diagnostic_set:
                arguments += ["--diagnostic-set", self.diagnostic_set]
            try:
                with HostMetrics(self, mode):
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise RuntimeError("Shared functional suite budget exhausted")
                    self.command(arguments, timeout=remaining)
                proof = runtime_record(output / "runtime-sets.json", "Shared functional sets")
                if (proof.get("completed") is not True or proof.get("success") is not True
                        or proof.get("suite") != self.suite or proof.get("mode") != mode
                        or proof.get("session_policy") != "fresh-per-test-set"
                        or proof.get("diagnostic_set") != self.diagnostic_set
                        or (self.diagnostic_set and proof.get("coverage_scope") != "selected-set")
                        or proof.get("expected_sets") != expected
                        or [item.get("name") for item in proof.get("sets", [])] != proof["expected_sets"]
                        or not all(item.get("success") is True and item.get("cleanup_errors") == []
                                   and item.get("server_exit_code") == 0
                                   and [step.get("script") for step in item.get("steps", [])]
                                       == [step.script for step in planned.steps]
                                   for item, planned in zip(proof["sets"], plan))):
                    raise RuntimeError("Shared functional test-set coverage did not pass")
                self.record["functional_sets"][mode] = proof
                self.record["hosts"] += [{"mode": mode, "test_set": item["name"], "host": item["host"]}
                                         for item in proof["sets"]]
                self.collect_startup_evidence()
                self.capture_sw_window(mode, "end")
                self.checkpoint()
            except Exception:
                self.capture_sw_window(mode, "failure")
                raise
            finally:
                self.collect_evidence(mode)
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
        if self.renderer == "software" and any(
                item.get("renderer") != "Apple Software Renderer" for item in records):
            raise RuntimeError("Explicit software renderer request did not produce Apple Software Renderer")
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
    parser.add_argument("--profile", choices=("visible-smoke", "hidden-full"), default="visible-smoke")
    parser.add_argument("--renderer", choices=("auto", "software"), default="auto")
    parser.add_argument("--diagnostic-set", choices=("drawing-save", "drawing-save-as", "drawings", "drawing-copy-first", "drawing-copy-reopen", "drawing-reopen-no-inspect"),
                        help="Focused manual diagnosis only; never full acceptance")
    parser.add_argument("--diagnostic-visible", action="store_true",
                        help="Visible-host comparison for a selected diagnostic set only")
    parser.add_argument("--cleanup-private", action="store_true")
    parser.add_argument("--check-shared-gates", action="store_true")
    args = parser.parse_args()
    if args.check_shared_gates:
        if args.profile == "visible-smoke":
            shared_visible_gate()
            return
        shared_gates()
        shared_sets_gate()
        for item in shared_plan("full"):
            for step in item.steps:
                if not (PROJECT / "Dependencies/SWCLI/scripts/ci" / step.script).is_file():
                    raise RuntimeError("Pinned SWCLI lacks functional entrypoint: " + step.script)
        return
    if args.cleanup_private:
        cleanup_runtime(ci_root())
        return
    if args.app is None or args.evidence is None:
        raise RuntimeError("--app and --evidence are required")
    gate = RuntimeGate(args.app, args.evidence, profile=args.profile, renderer=args.renderer,
                       diagnostic_set=args.diagnostic_set, diagnostic_visible=args.diagnostic_visible)
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
