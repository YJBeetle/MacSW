"""Offline tag-to-signing guards; no credentials, CAD, keychain or GitHub writes."""
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

PROJECT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, PROJECT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


policy = load("tag_policy_tests", "scripts/ci/tag-policy.py")
source = load("tag_signing_tests", "scripts/ci/signing-input.py")
publisher = load("tag_publisher_tests", "scripts/ci/publish-release.py")


def jobs():
    result = [{"name": "Build & package", "conclusion": "success"},
              {"name": "Validate version tag before private runtime", "conclusion": "success"}]
    for profile, step in (("visible-smoke", "Lightweight visible SOLIDWORKS smoke"),
                          ("hidden-full", "Hidden SOLIDWORKS verification")):
        result.append({"name": "SOLIDWORKS installation & runtime (" + profile + ")", "conclusion": "success",
                       "steps": [{"name": step, "conclusion": "success"}]})
    return result


class VersionTagTests(unittest.TestCase):
    def test_version_tag_requires_matching_source_and_master_ancestry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            def git(*args):
                return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()
            git("init", "-q")
            git("config", "user.name", "Offline test")
            git("config", "user.email", "test@example.invalid")
            (root / "config").mkdir()
            (root / "config/versions.env").write_text('APP_VERSION="1.2.3"\n')
            git("add", ".")
            git("commit", "-qm", "fixture")
            sha = git("rev-parse", "HEAD")
            git("update-ref", "refs/remotes/origin/master", sha)
            git("tag", "-a", "v1.2.3", "-m", "annotated fixture")
            with patch.object(policy, "PROJECT", root):
                self.assertEqual(policy.validate_tag("v1.2.3", sha)["source_sha"], sha)
                for tag, target in (("v1.2.3", "0" * 40), ("feature", sha)):
                    with self.assertRaises(RuntimeError):
                        policy.validate_tag(tag, target)
                git("tag", "v1.2.4")
                with self.assertRaisesRegex(RuntimeError, "APP_VERSION"):
                    policy.validate_tag("v1.2.4", sha)
                (root / "new").write_text("not merged")
                git("add", ".")
                git("commit", "-qm", "unmerged")
                new = git("rev-parse", "HEAD")
                git("tag", "v1.2.5")
                with self.assertRaises(subprocess.CalledProcessError):
                    policy.validate_tag("v1.2.5", new)

    def test_workflow_run_uses_build_source_not_default_branch_github_sha(self):
        sha = "a" * 40
        record = {"path": ".github/workflows/build-app.yml", "head_sha": sha, "head_branch": "v1.2.3",
                  "status": "completed", "conclusion": "success", "event": "push",
                  "repository": {"full_name": source.REPOSITORY},
                  "head_repository": {"full_name": source.REPOSITORY}}
        env = {"GITHUB_REPOSITORY": source.REPOSITORY, "GITHUB_REF": "refs/heads/master",
               "GITHUB_EVENT_NAME": "workflow_run", "GITHUB_SHA": "b" * 40}
        expected = {"source_sha": sha, "release_tag": "v1.2.3"}
        with patch.dict(os.environ, env, clear=True), patch.object(source, "api", return_value=record), \
                patch.object(source.policy, "validate_tag", return_value=expected) as check:
            self.assertEqual(source.resolve_source("123"), expected)
            check.assert_called_once_with("v1.2.3", sha)
        with self.assertRaises(RuntimeError):
            source.validate_run(record, sha, release_tag="v1.2.3", skip_runtime_check=True)
        bad = dict(record, event="workflow_dispatch")
        with patch.dict(os.environ, env, clear=True), patch.object(source, "api", return_value=bad), \
                self.assertRaisesRegex(RuntimeError, "actual version-tag push"):
            source.resolve_source("123")

    def test_live_tag_rechecked_after_approval_including_annotated_tags(self):
        target = {"object": {"type": "commit", "sha": "a" * 40}}
        with patch.object(source.policy, "validate_tag"), patch.object(source, "api", side_effect=[
                {"object": {"type": "tag", "sha": "f" * 40}}, target]):
            source.recheck_live_tag("v1.2.3", "a" * 40)
        with patch.object(source.policy, "validate_tag"), patch.object(source, "api", return_value=target), \
                self.assertRaisesRegex(RuntimeError, "moved"):
            source.recheck_live_tag("v1.2.3", "b" * 40)

    def test_both_profiles_and_secret_free_policy_are_mandatory_for_tag_signing(self):
        source.validate_jobs(jobs(), release_tag="v1.2.3")
        for index in range(4):
            data = jobs()
            data[index]["conclusion"] = "skipped"
            with self.subTest(index=index), self.assertRaises(RuntimeError):
                source.validate_jobs(data, release_tag="v1.2.3")
        data = jobs()
        data[-1]["steps"][0]["conclusion"] = "skipped"
        with self.assertRaises(RuntimeError):
            source.validate_jobs(data, release_tag="v1.2.3")
        with self.assertRaises(RuntimeError):
            source.validate_jobs(jobs(), release_tag="v1.2.3", skip_runtime_check=True)
        # A historical manual visible job and the new named matrix job both work.
        source.validate_jobs([jobs()[0], jobs()[2]])
        legacy = copy.deepcopy(jobs()[2])
        legacy["name"] = "SOLIDWORKS installation & runtime"
        source.validate_jobs([jobs()[0], legacy])


class RuntimeProofTests(unittest.TestCase):
    def visible(self):
        return {"completed": True, "phase": "completed", "profile": "visible-smoke", "diagnostic_set": None,
                "diagnostic_visible": False, "renderer_request": "auto", "server_exit_code": 0,
                "host_process_exited": True, "visible_smoke": {"state": "completed", "success": True,
                                                               "profile": "visible-open", "cleanup_errors": [],
                    "host": {"process_id": 12, "visible": True, "owned_by_daemon": True, "shared_interactive": False},
                    "host_after": {"process_id": 12, "visible": True, "owned_by_daemon": True, "shared_interactive": False}}}

    def hidden(self):
        ci = str(PROJECT / "Dependencies/SWCLI/scripts/ci")
        with patch.object(sys, "path", [ci] + sys.path):
            from gate_support.runtime_plan import runtime_plan
        plan = runtime_plan("full")
        rows = [{"name": item.name, "success": True, "cleanup_errors": [], "server_exit_code": 0,
                 "host": {"owned_by_daemon": True, "visible": False, "shared_interactive": False},
                 "before_start": {"verified": True, "native_process_ids": []},
                 "after_stop": {"verified": True, "native_process_ids": []},
                 "steps": [{"script": step.script, "success": True} for step in item.steps]} for item in plan]
        return {"completed": True, "phase": "completed", "profile": "hidden-full", "diagnostic_set": None,
                "diagnostic_visible": False, "renderer_request": "auto", "suite": "full", "full_acceptance_eligible": True,
                "functional_sets": {"hidden": {"completed": True, "success": True, "coverage_scope": "full-plan",
                    "suite": "full", "mode": "hidden", "session_policy": "fresh-per-test-set",
                    "diagnostic_set": None, "cleanup_errors": [], "expected_sets": [item.name for item in plan], "sets": rows}}}

    def test_real_receipt_profiles_require_completion_and_no_diagnostic_subset(self):
        for profile, record in (("visible-smoke", self.visible()), ("hidden-full", self.hidden())):
            source.validate_runtime_report(record, profile)
            for key, value in (("completed", False), ("diagnostic_set", "drawing-save"),
                               ("diagnostic_visible", True), ("renderer_request", "software"), ("error", {"type": "failure"})):
                with self.subTest(profile=profile, key=key), self.assertRaises(RuntimeError):
                    source.validate_runtime_report(dict(record, **{key: value}), profile)
        hidden = self.hidden()
        hidden["functional_sets"]["hidden"]["sets"][-1]["steps"][0]["success"] = False
        with self.assertRaisesRegex(RuntimeError, "steps or cleanup"):
            source.validate_runtime_report(hidden, "hidden-full")
        visible = self.visible()
        visible["host_process_exited"] = False
        with self.assertRaisesRegex(RuntimeError, "cleanly"):
            source.validate_runtime_report(visible, "visible-smoke")

    def test_runtime_artifact_downloads_are_digest_bound_and_profiles_do_not_overlap(self):
        artifacts, data = [], {}
        for index, (profile, report) in enumerate((("visible-smoke", self.visible()), ("hidden-full", self.hidden()))):
            output = io.BytesIO()
            with zipfile.ZipFile(output, "w") as archive:
                archive.writestr(profile + "/runtime.json", json.dumps(report))
            raw = output.getvalue()
            data[str(index)] = raw
            artifacts.append({"id": index, "name": "MacSW-SOLIDWORKS-runtime-evidence-" + profile,
                              "expired": False, "digest": "sha256:" + __import__('hashlib').sha256(raw).hexdigest(),
                              "workflow_run": {"id": 123, "head_sha": "a" * 40}})
        def download(args, stdout, **kwargs):
            stdout.write(data[args[-1].split('/')[-2]])
            return type("Result", (), {"returncode": 0})()
        with tempfile.TemporaryDirectory() as directory, patch.object(source.subprocess, "run", side_effect=download):
            proofs = source.runtime_proofs(artifacts, Path(directory), "123", "a" * 40)
            self.assertEqual(set(proofs), {"visible-smoke", "hidden-full"})
        artifacts[0]["digest"] = "sha256:" + "0" * 64
        with tempfile.TemporaryDirectory() as directory, patch.object(source.subprocess, "run", side_effect=download), \
                self.assertRaisesRegex(RuntimeError, "digest mismatch"):
            source.runtime_proofs(artifacts, Path(directory), "123", "a" * 40)


class PublisherBindingTests(unittest.TestCase):
    def test_workflow_run_candidate_source_is_distinct_from_default_branch_sha(self):
        record = {"head_sha": "b" * 40, "event": "workflow_run"}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "candidate.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("provenance.json", json.dumps({"source_commit": "a" * 40, "release_tag": "v1.2.3"}))
            with patch.object(publisher.signing.policy, "validate_tag") as check:
                self.assertEqual(publisher.candidate_source(record, path), ("a" * 40, "v1.2.3"))
                check.assert_called_once_with("v1.2.3", "a" * 40)
            with self.assertRaises(RuntimeError):
                publisher.candidate_source(dict(record, event="workflow_dispatch"), path)
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("provenance.json", json.dumps({"source_commit": "a" * 40}))
            with self.assertRaisesRegex(RuntimeError, "verified version tag"):
                publisher.candidate_source(record, path)

    def test_automatic_signing_requires_policy_signing_and_bootstrap_jobs(self):
        record = {"path": ".github/workflows/sign-app.yml", "head_branch": "master", "event": "workflow_run",
                  "status": "completed", "conclusion": "success", "head_sha": "b" * 40,
                  "repository": {"full_name": source.REPOSITORY}, "head_repository": {"full_name": source.REPOSITORY}}
        rows = [{"name": name, "conclusion": "success"} for name in
                ("verify-source", "sign-and-notarize", "verify-signed-bootstrap")]
        publisher.validate_signing_run(record, rows)
        with self.assertRaises(RuntimeError):
            publisher.validate_signing_run(record, rows[1:])
        with self.assertRaises(RuntimeError):
            publisher.validate_signing_run(record, rows + rows[:1])

    def test_tag_publication_keeps_tag_identity_when_master_has_advanced(self):
        values = {"APP_VERSION": "1.2.3", "APP_BUILD": "12", "SWCLI_SOURCE_COMMIT": "c" * 40}
        with patch.object(publisher.signing.policy, "validate_tag") as validate, \
                patch.object(publisher.signing.policy, "source_versions", return_value=values), \
                patch.object(publisher.signing.policy, "git", side_effect=["tag-public-key", "old version notes"]), \
                patch.object(publisher, "publisher_matches") as current_source, \
                patch.object(publisher, "versions", return_value={"APP_VERSION": "9.9.9"}) as latest_values:
            result = publisher.publication_source("a" * 40, "v1.2.3")
        self.assertEqual(result, (values, "tag-public-key", "old version notes"))
        validate.assert_called_once_with("v1.2.3", "a" * 40)
        current_source.assert_not_called()
        latest_values.assert_not_called()
        with patch.object(publisher, "publisher_matches") as current_source, \
                patch.object(publisher, "versions", return_value=values):
            self.assertEqual(publisher.publication_source("a" * 40, None), (values, None, None))
            current_source.assert_called_once_with("a" * 40)

    def test_publisher_reads_exact_tag_gitlink_plan_instead_of_current_dependencies(self):
        raw = (PROJECT / "Dependencies/SWCLI/scripts/ci/gate_support/runtime_plan.py").read_bytes()
        import base64
        with patch.object(source.policy, "source_versions", return_value={"SWCLI_SOURCE_COMMIT": "c" * 40}), \
                patch.object(source.policy, "git", return_value="160000 commit " + "c" * 40 + "\tDependencies/SWCLI"), \
                patch.object(source, "api", return_value={"encoding": "base64", "content": base64.b64encode(raw).decode()}) as api:
            plan = source.source_runtime_plan("a" * 40)
        self.assertEqual(len(plan), 19)
        self.assertEqual(sum(len(item.steps) for item in plan), 20)
        self.assertIn("ref=" + "c" * 40, api.call_args.args[0])
        with patch.object(source.policy, "source_versions", return_value={"SWCLI_SOURCE_COMMIT": "c" * 40}), \
                patch.object(source.policy, "git", return_value="160000 commit " + "d" * 40 + "\tDependencies/SWCLI"), \
                self.assertRaisesRegex(RuntimeError, "gitlink differs"):
            source.source_runtime_plan("a" * 40)

    def test_daily_master_build_does_not_enter_signing_or_publication_chain(self):
        text = (PROJECT / ".github/workflows/sign-app.yml").read_text()
        trigger = text.split("  workflow_run:", 1)[1].split("\npermissions:", 1)[0]
        self.assertIn("branches: ['v*']", trigger)
        self.assertNotIn("master", trigger.split("branches:", 1)[1])
        self.assertIn("github.event.workflow_run.event == 'push'", text)
        self.assertIn("startsWith(github.event.workflow_run.head_branch, 'v')", text)
        publisher_text = (PROJECT / ".github/workflows/publish-release.yml").read_text()
        self.assertIn("workflows: ['Developer ID Direct Distribution']", publisher_text)
        self.assertNotIn("workflows: ['Build & Package MacSW.app']", publisher_text)

    def test_workflow_orders_trusted_policy_exact_source_then_live_tag_before_secrets(self):
        text = (PROJECT / ".github/workflows/sign-app.yml").read_text()
        self.assertLess(text.index("ref: master"), text.index("--resolve-source"))
        self.assertLess(text.index("--resolve-source"), text.index("ref: ${{ steps.source.outputs.source_sha }}"))
        self.assertLess(text.index("--recheck-tag"), text.index("secrets.SIGNING_CERTIFICATE"))
        self.assertIn("digest-mismatch: error", text)
        self.assertNotIn("contents: write", text)


class NestedPrivacyTests(unittest.TestCase):
    def test_unverified_profile_screenshot_blocks_artifact_publication(self):
        privacy = load("tag_profile_privacy", "scripts/ci/redact-evidence.py")
        with tempfile.TemporaryDirectory() as directory:
            images = Path(directory) / "MacSW-runtime/evidence/hidden-full/screenshots"
            images.mkdir(parents=True)
            (images / "unsafe.png").write_bytes(b"not an authorized screenshot")
            (images / "unsafe.json").write_text("{}")
            with patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "RUNNER_TEMP": directory}, clear=True), \
                    self.assertRaisesRegex(RuntimeError, "Unverified screenshot"):
                privacy.main()



if __name__ == "__main__":
    unittest.main()
