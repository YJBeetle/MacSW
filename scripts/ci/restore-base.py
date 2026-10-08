"""Run the unchanged cache validator with safe, fail-closed failure evidence.

Kept separate from the snapshot producer so a diagnostic-only change does not
invalidate an official base and force another Drive installation. No checks are
relaxed: the original restore either succeeds or the job remains failed.
"""

import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import shutil
import sys

spec = importlib.util.spec_from_file_location("macsw_cache_restore", Path(__file__).with_name("bottle-cache.py"))
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)

CATEGORIES = {
    "Installed base cache format/context mismatch": "context-mismatch",
    "Installed base cache failed integrity validation": "inventory-mismatch",
    "Refusing to overwrite an existing test bottle": "destination-exists",
    "Refusing a snapshot root symlink": "snapshot-root-symlink",
    "License/configuration file found in official base; refusing cache": "prohibited-file",
}


def inventory_difference(expected, actual):
    missing = set(expected) - set(actual)
    added = set(actual) - set(expected)
    changed = [name for name in sorted(set(expected) & set(actual)) if expected[name] != actual[name]]
    fields = Counter()
    samples = []
    for name in changed:
        before, after = expected[name], actual[name]
        differences = [field for field in ("mode", "sha256", "link") if before.get(field) != after.get(field)]
        fields.update(differences)
        if len(samples) < 20:
            sample = {"path_sha256": hashlib.sha256(name.encode()).hexdigest(), "fields": differences}
            # Modes are numeric public metadata. Never expose filenames, link
            # targets, registry contents, credentials or exception text.
            for field, entry in (("expected_mode", before), ("actual_mode", after)):
                if isinstance(entry.get("mode"), int):
                    sample[field] = entry["mode"]
            samples.append(sample)
    return {"missing_files": len(missing), "added_files": len(added), "changed_files": len(changed),
            "changed_fields": dict(fields), "samples": samples}


def restore(context):
    runtime = cache.root()  # Fail before inspecting anything on a non-CI host.
    record = {"completed": False, "phase": "manifest", "source": "installed-base-cache"}
    expected = None
    observed = None
    original_inventory = cache.inventory

    def inspect_inventory(directory):
        nonlocal observed
        record["phase"] = "inventory"
        observed = original_inventory(directory)
        record["phase"] = "copy-or-evidence"
        return observed

    try:
        manifest = json.loads((runtime / "base-cache/manifest.json").read_text())
        expected = manifest.get("files")
        cache.inventory = inspect_inventory
        cache.restore_snapshot(context)
    except Exception as error:
        category = CATEGORIES.get(str(error), "unexpected-error") if isinstance(error, RuntimeError) else "unexpected-error"
        if isinstance(error, shutil.Error):
            category = "copy-error"
            failures = error.args[0] if error.args and isinstance(error.args[0], list) else []
            record["copy_error_count"] = len(failures)
            numbers = Counter()
            for item in failures:
                if isinstance(item, tuple) and len(item) == 3:
                    numbers.update(re.findall(r"\[Errno ([0-9]+)\]", str(item[2])))
            record["copy_errnos"] = dict(numbers)
        elif isinstance(error, OSError):
            category = "filesystem-error"
            record["errno"] = error.errno
        if category == "inventory-mismatch":
            record["phase"] = "inventory"
        record["error_category"] = category
        record["available_bytes"] = shutil.disk_usage(runtime).free
        record["destination_created"] = (runtime / "app-support/bottle").exists()
        if isinstance(expected, dict):
            record["expected_files"] = len(expected)
        if isinstance(observed, dict) and isinstance(expected, dict):
            record["observed_files"] = len(observed)
            record["inventory_difference"] = inventory_difference(expected, observed)
        evidence = runtime / "evidence"
        evidence.mkdir(exist_ok=True)
        (evidence / "cache-restore-failure.json").write_text(json.dumps(record, indent=2) + "\n")
        print("Official base restore failed: " + category + "; see cache-restore-failure.json.", file=sys.stderr)
        raise
    finally:
        cache.inventory = original_inventory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context", required=True)
    args = parser.parse_args()
    restore(args.context)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Do not print raw copy errors: they can contain arbitrary file paths.
        raise SystemExit(1)
