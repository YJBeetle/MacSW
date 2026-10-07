"""Final publication barrier for CI text evidence, never raw installer logs."""

import base64
import configparser
import json
import os
from pathlib import Path
import re
import sys


def sensitive_values(environment):
    values = set()
    serial = environment.get("SW_SERIAL_SOLIDWORKS", "")
    if serial:
        normalized = re.sub("[^A-Za-z0-9]", "", serial).upper()
        values.update((serial, normalized))
        groups = [normalized[index:index + 4] for index in range(0, len(normalized), 4)]
        values.update((" ".join(groups), "-".join(groups)))
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
    text = re.sub(r"(?i)((?:SOLIDWORKS|SIMULATION|MOTION|MBD)SERIALNUMBER\s*=\s*)[^\s\";]+",
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
    print("Runtime text evidence passed the publication privacy barrier.")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        # Config parser errors can quote credential-bearing lines. Never echo
        # those errors in Actions logs; block publication instead.
        print("Runtime evidence privacy barrier failed; artifact upload is disabled.", file=sys.stderr)
        raise SystemExit(1)
