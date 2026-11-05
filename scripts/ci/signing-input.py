"""Verify original build inputs before signing credentials.

Manual master signing keeps its explicit visible-smoke/override policy. Version
tags require a trusted exact tag, independent visible and hidden-full native
receipts, and immutable original App identity. No private fixtures are fetched.
"""
import argparse
import ast
import base64
from collections import namedtuple
import hashlib
import importlib.util
import plistlib
import json
import os
from pathlib import Path
import posixpath
import re
import shutil
import stat
import subprocess
import sys
import zipfile

PROJECT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT / "scripts"))
import sign_app

REPOSITORY = "YJBeetle/MacSW"
policy_spec = importlib.util.spec_from_file_location("macsw_tag_policy", PROJECT / "scripts/ci/tag-policy.py")
policy = importlib.util.module_from_spec(policy_spec)
policy_spec.loader.exec_module(policy)


def validate_run(run, sha, *, skip_runtime_check=False, release_tag=None):
    if release_tag and skip_runtime_check:
        raise RuntimeError("Version-tag signing cannot skip runtime verification")
    required = {"head_sha": sha, "head_branch": release_tag or "master",
                "path": ".github/workflows/build-app.yml"}
    if not skip_runtime_check:
        required.update(status="completed", conclusion="success")
    if (any(run.get(key) != value for key, value in required.items())
            or run.get("status") not in ("in_progress", "completed")
            or run.get("event") not in ("push", "workflow_dispatch")
            or run.get("repository", {}).get("full_name") != REPOSITORY
            or run.get("head_repository", {}).get("full_name") != REPOSITORY):
        raise RuntimeError("Signing requires a successful trusted build of this exact master commit")


def validate_jobs(jobs, *, skip_runtime_check=False, release_tag=None):
    builds = [job for job in jobs if job.get("name") == "Build & package"]
    if len(builds) != 1 or builds[0].get("conclusion") != "success":
        raise RuntimeError("Required build job did not pass")
    if release_tag:
        if skip_runtime_check:
            raise RuntimeError("Version-tag signing cannot skip runtime verification")
        policy_jobs = [j for j in jobs if j.get("name") == "Validate version tag before private runtime"]
        if len(policy_jobs) != 1 or policy_jobs[0].get("conclusion") != "success":
            raise RuntimeError("Version tag trust policy did not pass")
        for profile, step in (("visible-smoke", "Lightweight visible SOLIDWORKS smoke"),
                              ("hidden-full", "Hidden SOLIDWORKS verification")):
            matches = [j for j in jobs if j.get("name") == "SOLIDWORKS installation & runtime (" + profile + ")"]
            if len(matches) != 1 or matches[0].get("conclusion") != "success":
                raise RuntimeError("Version tag requires both runtime profiles")
            steps = [s for s in matches[0].get("steps", []) if s.get("name") == step]
            if len(steps) != 1 or steps[0].get("conclusion") != "success":
                raise RuntimeError("Version tag runtime profile was skipped or incomplete")
        return
    if skip_runtime_check:
        return
    matches = [job for job in jobs if job.get("name") in
               ("SOLIDWORKS installation & runtime", "SOLIDWORKS installation & runtime (visible-smoke)")]
    if len(matches) != 1 or matches[0].get("conclusion") != "success":
        raise RuntimeError("Signing requires visible smoke: missing or failed runtime job")
    steps = [step for step in matches[0].get("steps", []) if step.get("name") ==
             "Lightweight visible SOLIDWORKS smoke"]
    if len(steps) != 1 or steps[0].get("conclusion") != "success":
        raise RuntimeError("Signing requires visible smoke; installation-only or diagnostic runs are insufficient")


def validate_artifact(artifacts):
    matches = [item for item in artifacts if item.get("name") == "MacSW-macOS-App"]
    if len(matches) != 1 or matches[0].get("expired") is not False:
        raise RuntimeError("Exactly one unexpired MacSW App artifact is required")
    artifact = matches[0]
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", artifact.get("digest", "")):
        raise RuntimeError("GitHub artifact SHA-256 is missing")
    if not isinstance(artifact.get("id"), int) or artifact["id"] <= 0:
        raise RuntimeError("Invalid artifact ID")
    return artifact


def api(route):
    result = subprocess.run(["gh", "api", route], capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError("GitHub provenance request failed")
    return json.loads(result.stdout)


def validate_app_zip(path):
    # ditto understands symlinks; validate those before extracting, not after
    # a malicious link could redirect a later member outside the staging root.
    with zipfile.ZipFile(path) as archive:
        for item in archive.infolist():
            name = item.filename.rstrip("/")
            parts = name.split("/")
            if (any(part in ("", ".", "..") for part in parts) or "\\" in name
                    or not (name == "MacSW.app" or name.startswith("MacSW.app/")
                            or name == "__MACOSX" or name.startswith("__MACOSX/MacSW.app/"))):
                raise RuntimeError("Unsafe App ZIP member")
            mode = item.external_attr >> 16
            kind = stat.S_IFMT(mode)
            if kind not in (0, stat.S_IFREG, stat.S_IFDIR, stat.S_IFLNK):
                raise RuntimeError("Special file in App ZIP")
            if stat.S_ISLNK(mode):
                if item.file_size > 4096:
                    raise RuntimeError("Oversized bundle link")
                target = archive.read(item).decode("utf-8")
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
                if (posixpath.isabs(target) or not resolved.startswith("MacSW.app/")
                        or "\\" in target or "\x00" in target):
                    raise RuntimeError("Unsafe App ZIP symlink")


def resolve_source(run_id):
    if (os.environ.get("GITHUB_REPOSITORY") != REPOSITORY
            or os.environ.get("GITHUB_REF") != "refs/heads/master"
            or not re.fullmatch(r"[1-9][0-9]*", run_id)):
        raise RuntimeError("Signing source must be resolved by trusted master CI")
    event = os.environ.get("GITHUB_EVENT_NAME")
    if event == "workflow_dispatch":
        sha = os.environ["GITHUB_SHA"]
        if not re.fullmatch(r"[0-9a-f]{40}", sha):
            raise RuntimeError("Invalid manual signing SHA")
        return {"source_sha": sha, "release_tag": ""}
    if event != "workflow_run":
        raise RuntimeError("Unsupported signing event")
    record = api(f"repos/{REPOSITORY}/actions/runs/{run_id}")
    tag, sha = record.get("head_branch", ""), record.get("head_sha", "")
    validate_run(record, sha, release_tag=tag)
    if record.get("event") != "push":
        raise RuntimeError("Automatic signing requires an actual version-tag push")
    return policy.validate_tag(tag, sha)


def recheck_live_tag(tag, sha):
    policy.validate_tag(tag, sha)
    target = api(f"repos/{REPOSITORY}/git/ref/tags/{tag}")["object"]
    for _ in range(8):
        if target["type"] == "commit":
            break
        if target["type"] != "tag":
            raise RuntimeError("Live version tag is not a commit")
        target = api(f"repos/{REPOSITORY}/git/tags/{target['sha']}")["object"]
    if target["type"] != "commit" or target["sha"] != sha:
        raise RuntimeError("Version tag moved while waiting for signing approval")


def validate_runtime_report(record, profile, plan=None):
    if (record.get("completed") is not True or record.get("phase") != "completed"
            or record.get("profile") != profile or record.get("error") is not None
            or record.get("renderer_request") != "auto" or record.get("diagnostic_set") is not None
            or record.get("diagnostic_visible") is not False):
        raise RuntimeError("Runtime profile evidence is incomplete or diagnostic-only")
    if profile == "visible-smoke":
        proof = record.get("visible_smoke", {})
        if (proof.get("state") != "completed" or proof.get("success") is not True
                or proof.get("profile") != "visible-open" or proof.get("cleanup_errors") != []
                or record.get("server_exit_code") != 0 or record.get("host_process_exited") is not True
                or not all(proof.get(key, {}).get("owned_by_daemon") is True
                           and proof[key].get("visible") is True
                           and proof[key].get("shared_interactive") is False
                           and proof[key].get("process_id") == proof.get("host", {}).get("process_id")
                           for key in ("host", "host_after"))):
            raise RuntimeError("Visible runtime evidence did not cleanly complete")
    else:
        proof = record.get("functional_sets", {}).get("hidden", {})
        # Use the exact pinned shared public plan, not counts from an untrusted receipt.
        if plan is None:
            ci = str(PROJECT / "Dependencies/SWCLI/scripts/ci")
            if ci not in sys.path:
                sys.path.insert(0, ci)
            from gate_support.runtime_plan import runtime_plan
            plan = runtime_plan("full")
        names = [item.name for item in plan]
        if (record.get("suite") != "full" or record.get("full_acceptance_eligible") is not True
                or proof.get("completed") is not True or proof.get("success") is not True
                or proof.get("suite") != "full" or proof.get("mode") != "hidden"
                or proof.get("session_policy") != "fresh-per-test-set"
                or proof.get("coverage_scope") != "full-plan" or proof.get("diagnostic_set") is not None
                or proof.get("cleanup_errors") != [] or proof.get("expected_sets") != names
                or [r.get("name") for r in proof.get("sets", [])] != names):
            raise RuntimeError("Hidden full runtime plan did not pass")
        for item, row in zip(plan, proof["sets"]):
            if (row.get("success") is not True or row.get("cleanup_errors") != []
                    or row.get("server_exit_code") != 0
                    or [s.get("script") for s in row.get("steps", [])] != [s.script for s in item.steps]
                    or not all(s.get("success") is True for s in row["steps"])
                    or row.get("host", {}).get("owned_by_daemon") is not True
                    or row["host"].get("visible") is not False
                    or row["host"].get("shared_interactive") is not False
                    or not all(row.get(boundary, {}).get("verified") is True
                               and row[boundary].get("native_process_ids") == []
                               for boundary in ("before_start", "after_stop"))):
                raise RuntimeError("Hidden full runtime steps or cleanup failed")


def source_runtime_plan(sha):
    """Read the immutable tag's gitlink, never the publisher's newer checkout."""
    values = policy.source_versions(sha)
    pin = values.get("SWCLI_SOURCE_COMMIT", "")
    row = policy.git("ls-tree", sha, "Dependencies/SWCLI")
    if not re.fullmatch(r"160000 commit " + re.escape(pin) + r"\s+Dependencies/SWCLI", row):
        raise RuntimeError("Tag SWCLI gitlink differs from the pinned source version")
    item = api("repos/YJBeetle/SWCLI/contents/scripts/ci/gate_support/runtime_plan.py?ref=" + pin)
    if item.get("encoding") != "base64":
        raise RuntimeError("Missing exact pinned runtime plan")
    raw = base64.b64decode(item["content"])
    functions = [n for n in ast.parse(raw).body if isinstance(n, ast.FunctionDef) and n.name == "runtime_plan"]
    if len(functions) != 1:
        raise RuntimeError("Pinned runtime plan is ambiguous")
    # Evaluate only the reviewed pure plan function, without importing the rest
    # of the source module or using its module-level side effects.
    scope = {"Step": namedtuple("Step", "script kind args", defaults=((),)),
             "TestSet": namedtuple("TestSet", "name steps"), "tuple": tuple,
             "ValueError": ValueError, "__builtins__": {}}
    exec(compile(ast.Module(body=functions, type_ignores=[]), "pinned-runtime-plan", "exec"), scope)
    return scope["runtime_plan"]("full")


def runtime_proofs(artifacts, destination, run_id, sha, plan=None):
    proofs = {}
    for profile in ("visible-smoke", "hidden-full"):
        selected = [a for a in artifacts if a.get("name") == "MacSW-SOLIDWORKS-runtime-evidence-" + profile]
        if len(selected) != 1:
            raise RuntimeError("Both original runtime profile artifacts are required")
        item = selected[0]
        if (item.get("expired") is not False
                or item.get("workflow_run", {}).get("id") != int(run_id)
                or item.get("workflow_run", {}).get("head_sha") != sha
                or not re.fullmatch(r"sha256:[0-9a-f]{64}", item.get("digest", ""))):
            raise RuntimeError("Unbound runtime evidence artifact")
        path = destination / (profile + "-artifact.zip")
        with path.open("xb") as output:
            result = subprocess.run(["gh", "api", f"repos/{REPOSITORY}/actions/artifacts/{item['id']}/zip"],
                                    stdout=output, stderr=subprocess.PIPE, timeout=600)
        if result.returncode or "sha256:" + sign_app.digest(path) != item["digest"]:
            raise RuntimeError("Runtime artifact digest mismatch")
        with zipfile.ZipFile(path) as archive:
            expected = profile + "/runtime.json"
            if archive.namelist().count(expected) != 1:
                raise RuntimeError("Missing independent profile runtime receipt")
            raw = archive.read(expected)
            validate_runtime_report(json.loads(raw), profile, plan=plan)
        proofs[profile] = {"artifact_id": item["id"], "artifact_digest": item["digest"],
                           "runtime_sha256": hashlib.sha256(raw).hexdigest()}
    return proofs


def fetch(run_id, sha, destination, *, skip_runtime_check=False, release_tag=None):
    if not re.fullmatch(r"[1-9][0-9]*", run_id) or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise RuntimeError("Invalid build run ID or commit")
    if (os.environ.get("GITHUB_REPOSITORY") != REPOSITORY
            or os.environ.get("GITHUB_REF") != "refs/heads/master"
            or os.environ.get("GITHUB_EVENT_NAME") not in (("workflow_run",) if release_tag else ("workflow_dispatch",))):
        raise RuntimeError("Signing input is restricted to manual master CI")
    if release_tag:
        if skip_runtime_check:
            raise RuntimeError("Version tag cannot skip runtime checks")
        policy.validate_tag(release_tag, sha)
    run = api(f"repos/{REPOSITORY}/actions/runs/{run_id}")
    validate_run(run, sha, skip_runtime_check=skip_runtime_check, release_tag=release_tag)
    # More than 100 jobs is unexpected for this workflow; fail rather than
    # silently accepting a partial page.
    job_data = api(f"repos/{REPOSITORY}/actions/runs/{run_id}/jobs?per_page=100")
    if job_data.get("total_count") != len(job_data["jobs"]):
        raise RuntimeError("Unexpected paginated build jobs")
    validate_jobs(job_data["jobs"], skip_runtime_check=skip_runtime_check, release_tag=release_tag)
    data = api(f"repos/{REPOSITORY}/actions/runs/{run_id}/artifacts?per_page=100")
    if data.get("total_count") != len(data["artifacts"]):
        raise RuntimeError("Unexpected paginated build artifacts")
    artifact = validate_artifact(data["artifacts"])
    if release_tag and (artifact.get("workflow_run", {}).get("id") != int(run_id)
                        or artifact.get("workflow_run", {}).get("head_sha") != sha):
        raise RuntimeError("Original App artifact belongs to another source/run")
    destination.mkdir(parents=True, exist_ok=False)
    outer = destination / "github-artifact.zip"
    with outer.open("xb") as output:
        result = subprocess.run(["gh", "api", f"repos/{REPOSITORY}/actions/artifacts/{artifact['id']}/zip"],
                                stdout=output, stderr=subprocess.PIPE, timeout=600)
    if result.returncode or "sha256:" + sign_app.digest(outer) != artifact["digest"]:
        raise RuntimeError("GitHub App artifact digest mismatch; nothing extracted or signed")
    with zipfile.ZipFile(outer) as archive:
        apps = [item for item in archive.infolist()
                if re.fullmatch(r"build/archive/MacSW-[A-Za-z0-9._-]+-macOS.zip", item.filename)]
        if len(apps) != 1:
            raise RuntimeError("Expected exactly one App ZIP in the verified artifact")
        item = apps[0]
        # Do not extract arbitrary paths from the service archive.
        with archive.open(item) as source, (destination / "app.zip").open("xb") as target:
            shutil.copyfileobj(source, target)
    validate_app_zip(destination / "app.zip")
    runtime = runtime_proofs(data["artifacts"], destination, run_id, sha) if release_tag else None
    if release_tag:
        values = policy.source_versions(sha)
        with zipfile.ZipFile(destination / "app.zip") as archive:
            info = plistlib.loads(archive.read("MacSW.app/Contents/Info.plist"))
            manifest = plistlib.loads(archive.read("MacSW.app/Contents/Resources/BuildManifest.plist"))
        if (info.get("CFBundleShortVersionString") != values["APP_VERSION"]
                or info.get("CFBundleVersion") != values["APP_BUILD"]
                or manifest.get("SWCLIVersion") != values["SWCLI_VERSION"]
                or manifest.get("SWCLISourceCommit") != values["SWCLI_SOURCE_COMMIT"]):
            raise RuntimeError("Original App identity differs from exact release tag")
    provenance = {
        "format": 1, "repository": REPOSITORY, "build_run_id": run_id,
        "source_commit": sha, "artifact_id": artifact["id"],
        "artifact_digest": artifact["digest"], "app_archive": item.filename,
        "app_sha256": sign_app.digest(destination / "app.zip"),
        "runtime_verification": {
            "required": not skip_runtime_check,
            "result": ("visible-smoke-and-hidden-full-passed" if release_tag else
                       "skipped-by-manual-override" if skip_runtime_check else "visible-smoke-passed"),
        },
    }
    if release_tag:
        provenance.update(release_tag=release_tag, runtime_profiles=runtime)
    (destination / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    if skip_runtime_check:
        print("Trusted build verified; visible smoke explicitly NOT checked; App artifact digest verified.")
    else:
        label = "visible smoke and hidden full" if release_tag else "visible smoke"
        print("Trusted build and " + label + " verified; App artifact digest verified.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id")
    parser.add_argument("--sha")
    parser.add_argument("--release-tag")
    parser.add_argument("--resolve-source", action="store_true")
    parser.add_argument("--recheck-tag", action="store_true")
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--skip-runtime-check", action="store_true",
                        help="Manual release override: require successful build, but do not wait for CAD runtime")
    args = parser.parse_args()
    if args.recheck_tag:
        if (os.environ.get("GITHUB_REPOSITORY") != REPOSITORY
                or os.environ.get("GITHUB_REF") != "refs/heads/master"
                or os.environ.get("GITHUB_EVENT_NAME") != "workflow_run"
                or not args.sha or not args.release_tag):
            parser.error("Live tag recheck requires the trusted automatic signing workflow")
        recheck_live_tag(args.release_tag, args.sha)
    elif args.resolve_source:
        source = resolve_source(args.run_id)
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            for key, value in source.items():
                output.write(key + "=" + value + "\n")
    else:
        if not args.run_id or not args.sha or not args.destination:
            parser.error("--sha and --destination are required for artifact verification")
        fetch(args.run_id, args.sha, args.destination, skip_runtime_check=args.skip_runtime_check,
              release_tag=args.release_tag)
