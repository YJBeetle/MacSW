"""Secret-free version tag trust policy shared by build, signing and publisher."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

PROJECT = Path(__file__).resolve().parents[2]
TAG = re.compile(r"v[0-9]+\.[0-9]+\.[0-9]+\Z")


def git(*args):
    return subprocess.check_output(["git", "-C", str(PROJECT), *args], text=True).strip()


def source_versions(sha):
    data = git("show", sha + ":config/versions.env")
    return dict(re.findall(r'^([A-Z0-9_]+)="([^"\n]+)"$', data, re.M))


def validate_tag(tag, sha):
    if not TAG.fullmatch(tag) or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise RuntimeError("Expected a version tag and exact commit SHA")
    target = git("rev-parse", "--verify", "refs/tags/" + tag + "^{commit}")
    if target != sha:
        raise RuntimeError("Version tag moved from the verified source")
    subprocess.run(["git", "-C", str(PROJECT), "merge-base", "--is-ancestor", sha,
                    "refs/remotes/origin/master"], check=True, capture_output=True)
    if "v" + source_versions(sha).get("APP_VERSION", "") != tag:
        raise RuntimeError("Version tag differs from APP_VERSION")
    return {"source_sha": sha, "release_tag": tag}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    if (os.environ.get("GITHUB_REPOSITORY") != "YJBeetle/MacSW"
            or os.environ.get("GITHUB_EVENT_NAME") != "push"
            or not os.environ.get("GITHUB_REF", "").startswith("refs/tags/")):
        raise RuntimeError("Tag policy is restricted to upstream version-tag pushes")
    print(json.dumps(validate_tag(os.environ["GITHUB_REF"][10:], os.environ["GITHUB_SHA"])))


if __name__ == "__main__":
    main()
