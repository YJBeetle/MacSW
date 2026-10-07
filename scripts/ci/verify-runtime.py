"""Prepare MacSW hosts and run SWCLI-owned gates sequentially on the same COM host.

No CAD test operations or geometry assertions belong here. Shared gate scripts
and assertions live in the pinned SWCLI submodule. Paths are converted by the
packaged helper using actual bottle drive mappings, never by assuming Z:.
"""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time

PROJECT = Path(__file__).resolve().parents[2]
SHARED_GATES = ("verify-modeling.py", "verify-driving-dimensions.py")


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
                       "host_observations": [], "host_acquisitions": []}
        self.env = dict(os.environ, MACSW_WINEPREFIX=str(self.prefix), WINEPREFIX=str(self.prefix),
                        SWCLI_ENDPOINT="127.0.0.1:18495", PYTHONDONTWRITEBYTECODE="1",
                        # OLE trace emits millions of GUID/string events during
                        # cold startup and can distort its timing. Keep
                        # errors/warnings, exceptions and module-load evidence.
                        WINEDEBUG="-all,err+ole,warn+ole,+seh,+loaddll,+timestamp",
                        WINE_SOLIDWORKS_STARTUP_TIMEOUT="150")
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

    def command(self, arguments, *, timeout=180):
        started = time.monotonic()
        entry = {"arguments": list(map(str, arguments)), "completed": False}
        self.record["commands"].append(entry)
        self.checkpoint()
        try:
            result = subprocess.run(list(map(str, arguments)), env=self.env, cwd=self.cwd,
                                    stdin=subprocess.DEVNULL, capture_output=True, text=True,
                                    encoding="utf-8", errors="replace", timeout=timeout)
            entry.update(completed=True, exit_code=result.returncode, stdout=result.stdout, stderr=result.stderr)
            if result.returncode != 0:
                raise RuntimeError("Command failed; see runtime.json: " + str(arguments[0]))
            return result.stdout
        except subprocess.TimeoutExpired as error:
            entry.update(error="Outer command deadline exceeded", stdout=text_output(error.stdout),
                         stderr=text_output(error.stderr))
            raise
        finally:
            entry["duration_seconds"] = time.monotonic() - started
            self.checkpoint()

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
        self.command([self.helper, "prepare"])
        self.command([self.runtime_helper, "inspect", mode])
        self.phase(mode + ".startup")
        self.log = (self.evidence / (mode + "-daemon.log")).open("w")
        flags = ["--visible"] if mode == "visible" else []
        self.foreground = subprocess.Popen(
            [str(self.cli), "daemon", "serve", "--startup-timeout", "180", *flags],
            env=self.env, cwd=self.cwd, stdin=subprocess.DEVNULL, stdout=self.log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 210
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
            if self.foreground.wait(timeout=45) != 0:
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
                                 "--cli-command", self.cli, "--endpoint", self.env["SWCLI_ENDPOINT"]]
                    if name == "driving":
                        arguments += ["--after-modeling", self.cwd / mode / "modeling/modeling.json"]
                    self.command(arguments, timeout=2400)
                    self.same_host(host)
            finally:
                self.collect_evidence(mode)
            self.stop()
        self.record["completed"] = True
        self.phase("completed")


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
