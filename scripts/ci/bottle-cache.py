"""Cache the complete official installed bottle, never the private test overlay.

Snapshots are made after Wine stops and before license fixtures are installed.
Only the bottle is copied: host logs, rclone config, media and fixtures are not.
The owner authorized retaining the fake CI serial without rewriting hives or
binaries. License/configuration files remain prohibited. Hits are integrity checked and
copied into a new isolated runtime directory, never used in place.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys

FORMAT = 3


def root():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("GitHub Actions runner required")
    return Path(os.environ["RUNNER_TEMP"]).resolve() / "MacSW-runtime"


def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while block := stream.read(4 * 1024 * 1024):
            digest.update(block)
    return digest.hexdigest()


def inventory(directory):
    if directory.is_symlink():
        raise RuntimeError("Refusing a snapshot root symlink")
    entries = {}
    for path in sorted(directory.rglob("*")):
        relative = path.relative_to(directory).as_posix()
        if (relative.lower() == "drive_c/macsw/python311"
                or relative.lower().startswith("drive_c/macsw/python311/")):
            raise RuntimeError("SWCLI deployment found in official base; refusing cache")
        if path.is_symlink():
            entries[relative] = {"link": os.readlink(path)}
        elif path.is_file():
            if path.suffix.lower() == ".lic" or path.name.lower() in ("license.dat", "rclone.conf"):
                raise RuntimeError("License/configuration file found in official base; refusing cache")
            entries[relative] = {"sha256": digest_file(path), "mode": stat.S_IMODE(path.stat().st_mode)}
    return entries


def prune_snapshot(bottle):
    # Fixed, validated snapshot paths only. No deletion follows directory links.
    for path in [bottle / "drive_c/windows/temp", bottle / "drive_c/opt/FlexNet",
                 bottle / "drive_c/MacSW/Python311"]:
        if not path.parent.resolve().is_relative_to(bottle.resolve()):
            raise RuntimeError("Snapshot cleanup path escaped the bottle")
        if path.name == "FlexNet" and (path.exists() or path.is_symlink()):
            raise RuntimeError("Private FlexNet package cannot enter the official base cache")
        if path.is_symlink():
            path.unlink()
        elif path.exists():
            shutil.rmtree(path)
    for path in bottle.rglob("*"):
        if path.is_file() and not path.is_symlink() and path.suffix.lower() in (".log", ".dmp"):
            path.unlink()
    users = bottle / "drive_c/users"
    if users.is_dir() and not users.is_symlink():
        for user in users.iterdir():
            if user.is_symlink() or not user.is_dir():
                continue
            for relative in ("Temp", "AppData/Local/Temp"):
                path = user / relative
                if not path.parent.resolve().is_relative_to(bottle.resolve()):
                    raise RuntimeError("Snapshot user temporary path escaped the bottle")
                if path.is_symlink():
                    path.unlink()
                elif path.exists():
                    shutil.rmtree(path)
    # Media and runner-root drives are per-run state. Keep C:; the runtime
    # adapter creates its own M: mapping after restoring a clean copy.
    mappings = bottle / "dosdevices"
    for path in mappings.iterdir():
        if path.name != "c:":
            if not path.is_symlink():
                raise RuntimeError("Unexpected non-symlink drive mapping in snapshot")
            path.unlink()


def export_snapshot(context):
    runtime = root()
    setup = json.loads((runtime / "evidence/setup.json").read_text())
    if not setup.get("completed") or setup.get("fixture_ready") is not False:
        raise RuntimeError("Only a completed official installation before fixture injection can be cached")
    source = runtime / "app-support/bottle"
    cache = runtime / "base-cache"
    cache.mkdir()  # Never overwrite a restored or previously published snapshot.
    snapshot = cache / "bottle"
    try:
        # Wine must be stopped by the mount orchestrator before this copy.
        shutil.copytree(source, snapshot, symlinks=True)
        prune_snapshot(snapshot)
        entries = inventory(snapshot)
        if not any(name.lower().endswith("/sldworks.exe") for name in entries):
            raise RuntimeError("Official base snapshot lacks SOLIDWORKS")
        manifest = {"format": FORMAT, "context": context, "files": entries}
        (cache / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
        record = {"completed": True, "source": "fresh-install", "snapshot_files": len(entries)}
        write_evidence(runtime, record)
        print("Official installed bottle snapshot verified; authorized fake CI serial retained.")
    except Exception:
        shutil.rmtree(cache)
        raise


def restore_snapshot(context):
    runtime = root()
    cache = runtime / "base-cache"
    manifest = json.loads((cache / "manifest.json").read_text())
    if manifest.get("format") != FORMAT or manifest.get("context") != context:
        raise RuntimeError("Installed base cache format/context mismatch")
    snapshot = cache / "bottle"
    if inventory(snapshot) != manifest.get("files"):
        raise RuntimeError("Installed base cache failed integrity validation")
    destination = runtime / "app-support/bottle"
    if destination.exists() or destination.is_symlink():
        raise RuntimeError("Refusing to overwrite an existing test bottle")
    shutil.copytree(snapshot, destination, symlinks=True)
    write_evidence(runtime, {"completed": True, "source": "installed-base-cache",
                             "snapshot_files": len(manifest["files"])})
    print("Verified official base cache restored into a new isolated test bottle.")


def write_evidence(runtime, record):
    evidence = runtime / "evidence"
    evidence.mkdir(exist_ok=True)
    (evidence / "cache.json").write_text(json.dumps(record, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("export", "restore"))
    parser.add_argument("--context", required=True)
    args = parser.parse_args()
    if args.operation == "export":
        export_snapshot(args.context)
    else:
        restore_snapshot(args.context)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("Installed bottle cache privacy/integrity check failed; no snapshot is published.", file=sys.stderr)
        raise SystemExit(1)
