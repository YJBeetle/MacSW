"""Publication barrier for text logs and approved hosted CAD-stage screenshots."""

import base64
import configparser
import json
import hashlib
import os
from pathlib import Path
import re
import struct
import sys


def sensitive_values(environment):
    values = set()
    # The owner confirmed this repository's SOLIDWORKS SN is a fake CI fixture
    # and explicitly authorized retaining it in installation diagnostics.
    # Rclone credentials are real and must still be hidden.
    encoded = environment.get("RCLONE_CONFIG_B64", "")
    if encoded:
        values.add(encoded)
        config = configparser.ConfigParser(interpolation=None)
        config.read_string(base64.b64decode(encoded).decode("utf-8-sig"))
        for section in config.sections():
            for value in config[section].values():
                if len(value) >= 8:
                    values.add(value)
                try:
                    token = json.loads(value)
                except ValueError:
                    continue
                if isinstance(token, dict):
                    values.update(item for item in token.values() if isinstance(item, str) and len(item) >= 8)
    return sorted((value for value in values if value), key=len, reverse=True)


def redact(text, values):
    for value in values:
        text = re.sub(re.escape(value), "[REDACTED]", text, flags=re.IGNORECASE)
    # Other serial properties should not occur in runtime evidence, but fail
    # closed by hiding them if a future diagnostic accidentally prints them.
    text = re.sub(r"(?i)((?:SIMULATION|MOTION|MBD)SERIALNUMBER\s*=\s*)[^\s\";]+",
                  r"\1[REDACTED]", text)
    return text


def main():
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("GitHub Actions runner required")
    directory = Path(os.environ["RUNNER_TEMP"]).resolve() / "MacSW-runtime/evidence"
    if not directory.exists():
        return
    if directory.is_symlink():
        raise RuntimeError("Refusing an evidence directory symlink")
    values = sensitive_values(os.environ)
    # Binary screenshots cannot be text-redacted. Admit only hashed captures
    # from hosted CAD stages. Full desktop images were explicitly authorized;
    # neither installation nor credential/licensing setup is an allowed stage.
    for image in (directory / "screenshots").glob("*.png"):
        if image.is_symlink() or image.with_suffix(".json").is_symlink():
            raise RuntimeError("Screenshot symlink")
        receipt = json.loads(image.with_suffix(".json").read_text())
        data = image.read_bytes()
        source = receipt.get("source")
        valid_source = (source == "github-hosted-desktop"
                        and receipt.get("runner_environment") == "github-hosted"
                        and type(receipt.get("display_id")) is int and receipt["display_id"] == 1)
        if source == "owned-sw-window":
            valid_source = all(type(receipt.get(key)) is int and receipt[key] > 0
                               for key in ("unix_pid", "window_id"))
        if (not valid_source or receipt.get("success") is not True
                or receipt.get("owned_by_daemon") is not True or receipt.get("shared_interactive") is not False
                or receipt.get("phase") not in {mode + "." + stage for mode in ("visible", "hidden")
                                               for stage in ("modeling", "driving", "toolbox", "test-sets")}
                or receipt.get("file") != image.name
                or type(receipt.get("host_windows_pid")) is not int or receipt["host_windows_pid"] <= 0
                or not 24 <= len(data) <= 25 * 1024 * 1024
                or not data.startswith(b"\x89PNG\r\n\x1a\n")
                or any(not 1 <= dimension <= 16384 for dimension in struct.unpack(">II", data[16:24]))
                or (receipt.get("width"), receipt.get("height")) != struct.unpack(">II", data[16:24])
                or receipt.get("size_bytes") != len(data)
                or receipt.get("sha256") != hashlib.sha256(data).hexdigest()):
            raise RuntimeError("Unverified screenshot blocks publication")
    for path in directory.rglob("*"):
        if path.is_symlink():
            raise RuntimeError("Refusing an evidence symlink")
        if not path.is_file() or path.suffix not in (".json", ".log"):
            continue
        text = redact(path.read_text(encoding="utf-8", errors="strict" if path.suffix == ".json" else "replace"), values)
        # JSON remains parseable; do not publish a corrupt or partially replaced record.
        if path.suffix == ".json":
            json.loads(text)
        path.write_text(text, encoding="utf-8")
    print("Runtime evidence passed the publication privacy barrier.")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Config parser errors can quote credential-bearing lines. Never echo
        # those errors in Actions logs; block publication instead.
        print("Runtime evidence privacy barrier failed; artifact upload is disabled.", file=sys.stderr)
        raise SystemExit(1)
