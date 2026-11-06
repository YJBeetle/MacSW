"""Offline workflow contracts; never invoke App, Wine, credentials or CI."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

PROJECT = Path(__file__).resolve().parents[2]


class WorkflowSummaryTests(unittest.TestCase):
    def setUp(self):
        workflow = (PROJECT / ".github/workflows/build-app.yml").read_text()
        self.jobs = {
            "checks": workflow.split("\n  checks:\n", 1)[1].split("\n  build:\n", 1)[0],
            "build": workflow.split("\n  build:\n", 1)[1].split("\n  runtime-test:\n", 1)[0],
            "runtime": workflow.split("\n  runtime-test:\n", 1)[1],
        }

    def step(self, kind, upload=False):
        identifier = "upload-" + kind + "-summary" if upload else "summarize-" + kind
        for step in self.jobs[kind].split("      - name: ")[1:]:
            if "        id: " + identifier + "\n" in step:
                return step
        self.fail("Missing step " + identifier)

    def test_shared_cli_always_keeps_original_outcomes_and_separate_small_artifacts(self):
        for kind, job in self.jobs.items():
            step = self.step(kind)
            for expected in ("if: always()", "continue-on-error: true",
                             "python3 Dependencies/SWCLI/scripts/ci/summarize-tests.py",
                             "--evidence-root", "--output-dir", "--host macos-wine", "--scope",
                             '--source-commit "$SWCLI_SOURCE_COMMIT"', '--client-version "$SWCLI_VERSION"',
                             '--step-summary "$GITHUB_STEP_SUMMARY"'):
                self.assertIn(expected, step)
            declared = re.findall(r"^        id: ([a-z0-9-]+)$", job, re.M)
            self.assertEqual(len(declared), len(set(declared)))
            references = re.findall(r'--stage "([^=]+)=\$\{\{ steps\.([a-z0-9-]+)\.outcome', step)
            self.assertGreater(len(references), 3)
            for _, identifier in references:
                self.assertIn(identifier, declared)
                self.assertLess(job.index("id: " + identifier + "\n"), job.index("id: summarize-" + kind))
            self.assertNotIn(".conclusion", step)
            upload = self.step(kind, upload=True)
            for expected in ("if: always()", "continue-on-error: true", "archive: true", "summary.json",
                             "summary.md", "if-no-files-found: ignore"):
                self.assertIn(expected, upload)
            for excluded in ("private", "MacSW.app", "**/*.json"):
                self.assertNotIn(excluded, upload)

    def run_summary(self, kind, redaction="success", stages=None, summary_exit=0):
        temporary = tempfile.TemporaryDirectory(prefix="macsw summary contract ")
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        config = root / "scripts/lib/config.sh"
        config.parent.mkdir(parents=True)
        config.write_text("SWCLI_SOURCE_COMMIT=" + "a" * 40 + "\nSWCLI_VERSION=0.1.0a18\n")
        stub = root / "Dependencies/SWCLI/scripts/ci/summarize-tests.py"
        stub.parent.mkdir(parents=True)
        stub.write_text("""import argparse,json,os
from pathlib import Path
p=argparse.ArgumentParser()
for name in ('evidence-root','output-dir','host','scope','source-commit','client-version','step-summary'):p.add_argument('--'+name,required=True)
p.add_argument('--stage',action='append',default=[])
a=p.parse_args();out=Path(a.output_dir);out.mkdir(parents=True,exist_ok=True)
records={str(f.relative_to(a.evidence_root)):f.read_text() for f in Path(a.evidence_root).rglob('*.json')}
payload={'evidence_root':a.evidence_root,'records':records,'stages':a.stage,'host':a.host,'scope':a.scope}
(out/'summary.json').write_text(json.dumps(payload));(out/'summary.md').write_text('summary')
with open(a.step_summary,'a') as f:f.write('summary\\n')
raise SystemExit(int(os.environ.get('SUMMARY_EXIT','0')))
""")
        runner = root / "runner-temp"
        runner.mkdir()
        raw = runner / "MacSW-runtime/evidence"
        raw.mkdir(parents=True)
        raw.joinpath("receipt.json").write_text('{"token":"' + (
            "[REDACTED]" if redaction == "success" else "RAW_PRIVATE_TOKEN") + '"}')
        private = runner / "MacSW-runtime/private/assets"
        private.mkdir(parents=True)
        private.joinpath("private.json").write_text('{"token":"PRIVATE_LICENSE_INPUT"}')
        for name in ("toolbox-native-evidence", "write-buffers-evidence", "native-file-panel-evidence"):
            evidence = root / "build" / name
            evidence.mkdir(parents=True)
            evidence.joinpath("result.json").write_text('{"probe":"' + name + '"}')
        app = root / "build/app/MacSW.app"
        app.mkdir(parents=True)
        app.joinpath("not-a-receipt.json").write_text('{"ignored":"APP_INTERNAL_CONFIG"}')
        stages = stages or {}

        def expression(match):
            value = match.group(1).strip()
            if value == "runner.temp":
                return str(runner)
            if value == "matrix.profile":
                return "hidden-full"
            stage = re.fullmatch(r"steps\.([a-z0-9-]+)\.outcome \|\| 'skipped'", value)
            if stage:
                return stages.get(stage.group(1), "skipped")
            raise AssertionError("Unexpected expression " + value)

        script = textwrap.dedent(self.step(kind).split("        run: |\n", 1)[1])
        script = re.sub(r"\$\{\{(.*?)\}\}", expression, script)
        environment = dict(os.environ, RUNNER_TEMP=str(runner), MACSW_REDACTION_OUTCOME=redaction,
                           MACSW_SUMMARY_SCOPE="MacSW runtime hidden-full full all", SUMMARY_EXIT=str(summary_exit),
                           GITHUB_STEP_SUMMARY=str(root / "step-summary.md"))
        result = subprocess.run(["/bin/bash", "-e", "-o", "pipefail", "-c", script], cwd=root,
                                env=environment, capture_output=True, text=True, timeout=20)
        output = runner / "MacSW-ci-summary" / kind
        if kind == "runtime":
            output /= "hidden-full"
        return result, json.loads((output / "summary.json").read_text()), root

    def test_runtime_success_consumes_only_sanitized_public_evidence(self):
        self.assertLess(self.jobs["runtime"].index("id: redact-runtime"),
                        self.jobs["runtime"].index("id: summarize-runtime"))
        step = self.step("runtime")
        self.assertNotIn("secrets.", step)
        self.assertNotIn("MacSW-runtime/private", step)
        result, payload, root = self.run_summary("runtime", stages={"redact-runtime": "success", "hidden-full": "success"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(payload["evidence_root"], str(root / "runner-temp/MacSW-runtime/evidence"))
        self.assertEqual(payload["records"], {"receipt.json": '{"token":"[REDACTED]"}'})
        self.assertIn("hidden-full=success", payload["stages"])
        self.assertIn("visible-smoke=skipped", payload["stages"])
        self.assertNotIn("PRIVATE_LICENSE_INPUT", json.dumps(payload))

    def test_failed_cancelled_or_skipped_redaction_uses_a_fresh_empty_directory(self):
        for outcome in ("failure", "cancelled", "skipped", ""):
            with self.subTest(outcome=outcome):
                result, payload, root = self.run_summary("runtime", redaction=outcome,
                                                        stages={"redact-runtime": outcome or "skipped", "hidden-full": "failure"})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(payload["records"], {})
                self.assertTrue(Path(payload["evidence_root"]).name.startswith("macsw-runtime-summary-empty."))
                self.assertIn("hidden-full=failure", payload["stages"])
                for content in (json.dumps(payload), result.stdout, result.stderr, (root / "step-summary.md").read_text()):
                    self.assertNotIn("RAW_PRIVATE_TOKEN", content)
                    self.assertNotIn("PRIVATE_LICENSE_INPUT", content)

    def test_build_copies_only_the_three_public_probe_directories(self):
        result, payload, _ = self.run_summary("build", stages={"archive-app": "success", "write-buffers": "failure"})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(set(payload["records"]), {name + "/result.json" for name in (
            "toolbox-native-evidence", "write-buffers-evidence", "native-file-panel-evidence")})
        self.assertIn("write-buffers=failure", payload["stages"])
        self.assertNotIn("APP_INTERNAL_CONFIG", json.dumps(payload))
        self.assertNotIn("PRIVATE_LICENSE_INPUT", json.dumps(payload))

    def test_checks_are_stage_only_and_summary_failures_do_not_override_test_stages(self):
        result, payload, _ = self.run_summary("checks", stages={"unit-tests": "failure"}, summary_exit=23)
        self.assertEqual(result.returncode, 23)
        self.assertEqual(payload["records"], {})
        self.assertIn("unit-tests=failure", payload["stages"])
        self.assertIn("continue-on-error: true", self.step("checks"))
        self.assertIn("continue-on-error: true", self.step("checks", upload=True))


if __name__ == "__main__":
    unittest.main()
