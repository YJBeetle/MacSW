"""Mount only the ISO's parent directory via rclone NFS, then use MacSWCore.

No FUSE driver or full ISO download. All credentials, VFS blocks and mount logs
stay private. Never recursively delete the mountpoint, even when cleanup fails.
"""

import argparse
import base64
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import signal
import shutil
import subprocess
import sys
import time


def ci_root():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("GitHub Actions runner required")
    return Path(os.environ["RUNNER_TEMP"]).resolve() / "MacSW-runtime"


def media_location(value):
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or path.suffix.lower() != ".iso" or ":" in value:
        raise RuntimeError("Expected a relative ISO path in the gdrive remote")
    return "gdrive:" + str(path.parent), path.name


def mounted(mountpoint):
    result = subprocess.run(["/sbin/mount"], capture_output=True, text=True, check=True, timeout=10)
    return any(" on " + str(mountpoint) + " (" in line and "nfs" in line
               for line in result.stdout.splitlines())


def mount_command(config, remote, mountpoint, file_list, cache):
    return [
        "rclone", "--config", str(config), "nfsmount", remote, str(mountpoint),
        "--files-from-raw", str(file_list), "--sudo", "--read-only",
        # rclone serves NFSv3 without a network lock manager. hdiutil needs
        # advisory locks; satisfy them in this one runner's VFS, not via NLM.
        "--option", "ro,locallocks,intr", "--vfs-cache-mode", "full",
        "--cache-dir", str(cache), "--vfs-cache-max-size", "8G",
        "--vfs-cache-min-free-space", "4G", "--vfs-cache-poll-interval", "10s",
        "--buffer-size", "1M", "--vfs-read-ahead", "0",
        "--vfs-read-chunk-size", "4M", "--vfs-read-chunk-size-limit", "16M",
        "--poll-interval", "0", "--dir-cache-time", "24h"]


def prerequisite_diagnostics(root):
    """Publish codes only, not free-form installer text, paths or properties."""
    logs = root / "app-support/logs"
    records = {}
    if logs.is_dir() and not logs.is_symlink():
        for path in sorted(logs.glob("vcredist*.log")):
            if path.is_symlink() or not path.is_file():
                continue
            # Burn logs may be UTF-16; code extraction never publishes raw text.
            with path.open("rb") as stream:
                data = stream.read(1024 * 1024)
            encoding = "utf-16" if data.startswith((b"\xff\xfe", b"\xfe\xff")) else "utf-8-sig"
            text = data.decode(encoding, errors="replace")
            codes = re.findall(r"(?i)\b(?:error|result|hr)\s*[:=]?\s*(0x[0-9a-f]{8})\b", text)
            # Do not publish arbitrary filenames (MSI properties can supply them).
            records[str(len(records))] = {"bytes": path.stat().st_size,
                "is_wine_log": path.name == "vcredist-wine.log",
                "codes": sorted(set(code.lower() for code in codes))}
    evidence = root / "evidence"
    evidence.mkdir(exist_ok=True)
    (evidence / "prerequisite-diagnostics.json").write_text(
        json.dumps({"vc_log_created": (logs / "vcredist-x64.log").is_file(), "logs": records}, indent=2) + "\n")


def stop_mount(root, process=None):
    if root != ci_root():
        raise RuntimeError("Refusing cleanup outside the isolated CI root")
    mountpoint = root / "media-mount"
    # BootstrapStore normally detaches its image. Cover interruptions too, but
    # only images backed by this exact CI mount, not any unrelated runner image.
    result = subprocess.run(["/usr/bin/hdiutil", "info", "-plist"], capture_output=True,
                            check=True, timeout=15)
    for image in plistlib.loads(result.stdout).get("images", []):
        path = image.get("image-path", "")
        if not path.startswith(str(mountpoint) + "/"):
            continue
        devices = [entry.get("dev-entry", "") for entry in image.get("system-entities", [])]
        disk = next((device for device in devices if re.fullmatch(r"/dev/disk\d+", device)), None)
        if disk:
            subprocess.run(["/usr/bin/hdiutil", "detach", disk, "-force"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=30)
    if mounted(mountpoint):
        subprocess.run(["sudo", "-n", "/sbin/umount", "-f", str(mountpoint)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True, timeout=30)
    if process is not None:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
    else:
        state = root / "private/mount-process.json"
        if state.is_file():
            pid = json.loads(state.read_text())["pid"]
            result = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "command="],
                                    capture_output=True, text=True, timeout=10)
            # Do not signal a reused PID or another rclone invocation.
            if result.returncode == 0 and "nfsmount" in result.stdout and str(mountpoint) in result.stdout:
                os.kill(pid, signal.SIGTERM)
    if mountpoint.exists() and not mounted(mountpoint):
        mountpoint.rmdir()  # Empty local directory only; never rmtree a network mount.


def install():
    root = ci_root()
    private = root / "private"
    private.mkdir(parents=True, exist_ok=True, mode=0o700)
    mountpoint = root / "media-mount"
    mountpoint.mkdir()  # Refuse any pre-existing mountpoint/state.
    remote, filename = media_location(os.environ["MACSW_MEDIA_PATH"])
    file_list = private / "mount-files.txt"
    file_list.write_text(filename + "\n")
    config = private / "mount-rclone.conf"
    descriptor = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(base64.b64decode(os.environ["RCLONE_CONFIG_B64"], validate=True))
    child_env = dict(os.environ)
    child_env.pop("RCLONE_CONFIG_B64", None)
    mount_env = dict(child_env)
    mount_env.pop("SW_SERIAL_SOLIDWORKS", None)
    helper = root / "MacSW.app/Contents/MacOS/MacSWCI"
    child_env.update(MACSW_CI_MEDIA=str(mountpoint / filename), MACSW_CI_ASSETS=str(private / "assets"))
    initial_free = os.statvfs(root).f_bavail * os.statvfs(root).f_frsize
    minimum_free = initial_free
    process = None
    installation = None
    record = {"completed": False, "transport": "rclone-nfsmount", "initial_free_bytes": initial_free}
    try:
        with (private / "mount.log").open("w") as log:
            process = subprocess.Popen(mount_command(config, remote, mountpoint, file_list, private / "vfs"),
                env=mount_env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)
            (private / "mount-process.json").write_text(json.dumps({"pid": process.pid}))
            deadline = time.monotonic() + 90
            while not mounted(mountpoint):
                if process.poll() is not None or time.monotonic() >= deadline:
                    raise RuntimeError("Read-only rclone NFS mount failed or timed out; diagnostics kept private")
                time.sleep(1)
            subprocess.run(["/bin/test", "-s", str(mountpoint / filename)], check=True, timeout=30)
            print("ISO mounted read-only; installing through MacSWCore with on-demand reads.", flush=True)
            installation = subprocess.Popen([str(helper), "install"], env=child_env, stdin=subprocess.DEVNULL)
            deadline = time.monotonic() + 6900
            while installation.poll() is None:
                stats = os.statvfs(root)
                minimum_free = min(minimum_free, stats.f_bavail * stats.f_frsize)
                if process.poll() is not None:
                    raise RuntimeError("rclone exited while installation was using the media")
                if time.monotonic() >= deadline:
                    raise RuntimeError("MacSW installation exceeded its outer deadline")
                time.sleep(2)
            if installation.returncode != 0:
                raise RuntimeError("MacSWCore installation failed; see sanitized setup evidence")
            record["installation_completed"] = True
    finally:
        try:
            prerequisite_diagnostics(root)
        except Exception:
            # An evidence failure must not prevent process/mount cleanup.
            print("VC++ code-only diagnostics unavailable; private cleanup continues.", file=sys.stderr)
        if installation is not None and installation.poll() is None:
            installation.terminate()
            try:
                installation.wait(timeout=10)
            except subprocess.TimeoutExpired:
                installation.kill()
                installation.wait(timeout=5)
        try:
            # Release Wine's media handles before unmounting, including failed MSI.
            if helper.is_file():
                subprocess.run([str(helper), "cleanup"], env=mount_env, stdin=subprocess.DEVNULL,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=90, check=True)
        finally:
            try:
                stop_mount(root, process)
                record["mount_cleanup_completed"] = True
            finally:
                config.unlink(missing_ok=True)
                record["minimum_free_bytes"] = minimum_free
                cache = private / "vfs"
                if cache.exists():
                    size = subprocess.run(["/usr/bin/du", "-sk", str(cache)], capture_output=True,
                                          text=True, check=True, timeout=30)
                    record["vfs_allocated_bytes"] = int(size.stdout.split()[0]) * 1024
                    if record.get("mount_cleanup_completed"):
                        shutil.rmtree(cache)  # Exact local cache only, after NFS and ISO unmount.
                record["completed"] = bool(record.get("installation_completed") and record.get("mount_cleanup_completed"))
                evidence = root / "evidence"
                evidence.mkdir(exist_ok=True)
                (evidence / "media.json").write_text(json.dumps(record, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cleanup", action="store_true")
    args = parser.parse_args()
    if args.cleanup:
        stop_mount(ci_root())
    else:
        install()


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Cloud/decoder exceptions can include tokens; never print their text.
        print("CI media mount/installation failed; credentials and mount diagnostics remain private.", file=sys.stderr)
        raise SystemExit(1)
