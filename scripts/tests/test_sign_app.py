"""Offline signing policy/provenance tests; no keys or Apple service needed."""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import struct
import stat
import tempfile
import unittest
import zipfile
from unittest.mock import patch
from types import SimpleNamespace

PROJECT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, PROJECT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


signing = load("macsw_signing", "scripts/sign_app.py")
source = load("macsw_signing_input", "scripts/ci/signing-input.py")
notary = load("macsw_notary", "scripts/ci/notarize-app.py")


def thin(kind, *, endian="<", wide=True):
    magic = 0xFEEDFACF if wide else 0xFEEDFACE
    return struct.pack(endian + "IIIIIIII", magic, 0, 0, kind, 0, 0, 0, 0)


class SigningInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / "MacSW.app"
        self.app.mkdir()
        for relative in signing.EXECUTABLES:
            self.file(relative, thin(2))

    def file(self, relative, data):
        path = self.app / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def test_actual_headers_not_extensions_and_order(self):
        module = "Contents/Frameworks/wine/lib/wine/x86_64-unix/winemac.so"
        self.file(module, thin(6))
        self.file("Contents/MacOS/sw-cli", b"#!/bin/sh\n")
        self.file("Contents/Frameworks/wine/lib/native-looking.dll", b"MZPE")
        entries = signing.inventory(self.app)
        self.assertEqual(entries[0]["path"], module)
        self.assertEqual(len(entries), len(signing.EXECUTABLES) + 1)
        self.assertEqual(sum(item["policy"] == "wine" for item in entries), 2)

    def test_universal_32_and_64_endian_headers(self):
        for endian in ("<", ">"):
            for wide in (False, True):
                magic = 0xCAFEBABF if wide else 0xCAFEBABE
                fmt = "IIQQII" if wide else "IIIII"
                offset = 40 if wide else 28
                data = struct.pack(endian + "II", magic, 1)
                data += struct.pack(endian + fmt, *([0, 0, offset, 32, 0, 0] if wide
                                                    else [0, 0, offset, 32, 0]))
                data += thin(2, endian=endian)
                path = self.file("universal", data)
                self.assertEqual(signing.macho_type(path), 2)

    def test_universal_inconsistent_slices_are_rejected(self):
        data = struct.pack(">II", 0xCAFEBABE, 2)
        data += struct.pack(">IIIII", 0, 0, 48, 32, 0)
        data += struct.pack(">IIIII", 0, 0, 80, 32, 0)
        path = self.file("universal", data + thin(2) + thin(6))
        with self.assertRaisesRegex(RuntimeError, "different file types"):
            signing.macho_type(path)

    def test_bad_macho_headers_fail_closed(self):
        for data in (b"\xcf\xfa\xed\xfe", struct.pack(">II", 0xCAFEBABE, 30),
                     struct.pack(">II", 0xCAFEBABE, 1),
                     struct.pack(">IIIIIII", 0xCAFEBABE, 1, 0, 0, 3, 32, 0) + thin(6)):
            with self.subTest(data=data), self.assertRaises(RuntimeError):
                signing.macho_type(self.file("broken", data))

    def test_internal_alias_not_signed_twice(self):
        path = self.app / "Contents/Frameworks/wine/bin/wineloader"
        path.symlink_to("wine")
        self.assertEqual(len(signing.inventory(self.app)), len(signing.EXECUTABLES))

    def test_external_absolute_and_broken_links_rejected(self):
        link = self.app / "bad-link"
        for target in ("../external", "missing", str(self.app / "Contents/MacOS/MacSW")):
            link.symlink_to(target)
            with self.assertRaisesRegex(RuntimeError, "bundle link"):
                signing.inventory(self.app)
            link.unlink()

    def test_unknown_code_or_nested_bundle_requires_review(self):
        for relative, kind in (("Contents/MacOS/new-helper", 2),
                               ("Contents/Resources/hidden.bin", 6),
                               ("Contents/Frameworks/wine/lib/object.o", 1)):
            path = self.file(relative, thin(kind))
            with self.assertRaisesRegex(RuntimeError, "Unreviewed"):
                signing.inventory(self.app)
            path.unlink()
        (self.app / "Contents/Frameworks/Unexpected.framework").mkdir()
        with self.assertRaisesRegex(RuntimeError, "Nested code bundle"):
            signing.inventory(self.app)

    def test_required_executable_missing(self):
        (self.app / "Contents/MacOS/7zz").unlink()
        with self.assertRaisesRegex(RuntimeError, "Required native"):
            signing.inventory(self.app)

    def test_entitlement_files_exact_and_no_blanket_exceptions(self):
        for policy, expected in signing.ENTITLEMENTS.items():
            self.assertEqual(plistlib.loads((PROJECT / "resources/signing" / (policy + ".plist")).read_bytes()),
                             expected)
        self.assertEqual(signing.ENTITLEMENTS["default"], {})
        for forbidden in ("com.apple.security.cs.disable-library-validation",
                          "com.apple.security.get-task-allow", "com.apple.security.app-sandbox",
                          "com.apple.security.cs.allow-dyld-environment-variables"):
            self.assertFalse(any(forbidden in policy for policy in signing.ENTITLEMENTS.values()))

    def manifest(self):
        values = {"MonoVersion": "11.3.0", "WineVersion": "fixture", "SourceSHA256": "keep"}
        for key, relative in signing.wine_runtime.MODULES.items():
            values[key] = "old"
            self.file("Contents/Frameworks/wine/" + relative.format(**values), b"fixture")
        path = self.app / "Contents/Resources/BuildManifest.plist"
        self.file(str(path.relative_to(self.app)), plistlib.dumps(values))
        return path, values

    def test_rehash_only_four_signed_modules_not_pe_or_mono(self):
        path, old = self.manifest()
        signing.refresh_signed_hashes(self.app)
        new = plistlib.loads(path.read_bytes())
        self.assertEqual({key for key in old if old[key] != new[key]}, set(signing.SIGNED_MODULES))
        for key in signing.SIGNED_MODULES:
            self.assertEqual(new[key], signing.digest(self.app / "Contents/Frameworks/wine" /
                                                     signing.wine_runtime.MODULES[key]))

    def test_sign_order_no_deep_and_payload_checked_before_rehash(self):
        calls = []
        entries = signing.inventory(self.app)
        with patch.object(signing, "command", side_effect=lambda command: calls.append(command) or b""), \
                patch.object(signing, "verify_payload", side_effect=lambda _: calls.append(["payload"])), \
                patch.object(signing, "refresh_signed_hashes", side_effect=lambda _: calls.append(["rehash"])), \
                patch.object(signing, "verify"), contextlib.redirect_stdout(io.StringIO()):
            signing.sign(self.app, "Developer ID Application: Fixture (ABCDEFGHIJ)", "ABCDEFGHIJ",
                         Path("fixture.keychain-db"), PROJECT / "resources/signing")
        self.assertEqual(calls[0], ["payload"])
        self.assertEqual(calls[-3:-1], [["rehash"], ["payload"]])
        self.assertEqual(calls[-1][-1], self.app)
        sign_calls = [call for call in calls if call[0] == "/usr/bin/codesign"]
        self.assertEqual(len(sign_calls), len(entries))
        for call in sign_calls:
            self.assertNotIn("--deep", call)
            self.assertIn("--timestamp", call)
            self.assertIn("runtime", call)

    def test_developer_id_not_adhoc_and_team_required(self):
        for identity, team in (("-", "ABCDEFGHIJ"), ("Apple Development: Fixture", "ABCDEFGHIJ"),
                               ("Developer ID Application: Fixture", "bad")):
            with self.assertRaises(RuntimeError):
                signing.sign(self.app, identity, team, Path("unused"), PROJECT / "resources/signing")

    def test_signature_checks_team_developer_id_timestamp_runtime(self):
        good = b"Authority=Developer ID Application: Fixture\nTeamIdentifier=ABCDEFGHIJ\nTimestamp=Oct 11\nCodeDirectory v=20500 flags=0x10000(runtime)\n"
        signing.validate_details(good, "ABCDEFGHIJ")
        for missing in (b"Authority=Developer ID Application: Fixture\n", b"TeamIdentifier=ABCDEFGHIJ\n",
                        b"Timestamp=Oct 11\n", b"CodeDirectory v=20500 flags=0x10000(runtime)\n"):
            with self.assertRaises(RuntimeError):
                signing.validate_details(good.replace(missing, b""), "ABCDEFGHIJ")

    def test_entitlements_mismatch_rejected(self):
        good = b"Authority=Developer ID Application: Fixture\nTeamIdentifier=ABCDEFGHIJ\nTimestamp=Oct 11\nCodeDirectory flags=0x10000(runtime)\n"
        with patch.object(signing, "command", side_effect=[b"", good, plistlib.dumps({"unexpected": True})]):
            with self.assertRaisesRegex(RuntimeError, "Unexpected entitlements"):
                signing.verify_signature(self.app, "app", "ABCDEFGHIJ")


class SigningProvenanceTests(unittest.TestCase):
    def test_corrupt_download_rejected_before_extracting(self):
        with tempfile.TemporaryDirectory() as directory:
            jobs = [{"name": "Build & package", "conclusion": "success"},
                    {"name": "SOLIDWORKS installation & runtime", "conclusion": "success", "steps": [
                        {"name": "Shared modeling, driving dimensions and Toolbox on one host", "conclusion": "success"}]}]
            artifact = {"id": 123, "name": "MacSW-macOS-App", "expired": False, "digest": "sha256:" + "a" * 64}
            destination = Path(directory) / "download"
            def download(args, **kwargs):
                kwargs["stdout"].write(b"corrupted-artifact")
                return SimpleNamespace(returncode=0)
            with patch.dict(os.environ, GITHUB_REPOSITORY=source.REPOSITORY,
                            GITHUB_REF="refs/heads/master", GITHUB_EVENT_NAME="workflow_dispatch"), \
                    patch.object(source, "api", side_effect=[self.run_record(),
                        {"total_count": 2, "jobs": jobs}, {"total_count": 1, "artifacts": [artifact]}]), \
                    patch.object(source.subprocess, "run", side_effect=download):
                with self.assertRaisesRegex(RuntimeError, "digest mismatch"):
                    source.fetch("123", "a" * 40, destination)
            self.assertFalse((destination / "app.zip").exists())

    def test_archive_paths_and_symlinks_validated_before_ditto(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.zip"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("MacSW.app/Contents/MacOS/MacSW", b"fixture")
                link = zipfile.ZipInfo("MacSW.app/Contents/MacOS/alias")
                link.external_attr = (stat.S_IFLNK | 0o777) << 16
                archive.writestr(link, "MacSW")
                archive.writestr("__MACOSX/MacSW.app/Contents/._Info.plist", b"metadata")
            source.validate_app_zip(path)
            for name in ("../outside", "MacSW.app/../outside", "/absolute", "other.app/Contents/file"):
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr(name, b"fixture")
                with self.assertRaises(RuntimeError):
                    source.validate_app_zip(path)
            for target in ("../../../../outside", "/tmp/outside"):
                with zipfile.ZipFile(path, "w") as archive:
                    archive.writestr(link, target)
                with self.assertRaises(RuntimeError):
                    source.validate_app_zip(path)

    def run_record(self):
        return {"status": "completed", "conclusion": "success", "head_sha": "a" * 40,
                "head_branch": "master", "path": ".github/workflows/build-app.yml", "event": "push",
                "repository": {"full_name": source.REPOSITORY},
                "head_repository": {"full_name": source.REPOSITORY}}

    def test_only_successful_exact_master_trusted_build(self):
        record = self.run_record()
        source.validate_run(record, "a" * 40)
        for field, value in (("status", "in_progress"), ("conclusion", "failure"),
                             ("head_sha", "b" * 40), ("head_branch", "branch"), ("event", "pull_request"),
                             ("path", "other.yml"), ("head_repository", {"full_name": "fork/MacSW"})):
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                source.validate_run(dict(record, **{field: value}), "a" * 40)

    def test_full_gate_required_not_skipped_install_only(self):
        jobs = [{"name": "Build & package", "conclusion": "success"},
                {"name": "SOLIDWORKS installation & runtime", "conclusion": "success", "steps": [
                    {"name": "Shared modeling, driving dimensions and Toolbox on one host", "conclusion": "success"}]}]
        source.validate_jobs(jobs)
        for conclusion in ("skipped", "failure", "cancelled", None):
            jobs[1]["steps"][0]["conclusion"] = conclusion
            with self.assertRaises(RuntimeError):
                source.validate_jobs(jobs)
        with self.assertRaises(RuntimeError):
            source.validate_jobs(jobs[:1])

    def test_exact_unexpired_artifact_requires_sha256(self):
        artifact = {"id": 123, "name": "MacSW-macOS-App", "expired": False, "digest": "sha256:" + "a" * 64}
        self.assertEqual(source.validate_artifact([artifact]), artifact)
        for changes in ({"expired": True}, {"digest": ""}, {"id": "123"}):
            with self.assertRaises(RuntimeError):
                source.validate_artifact([dict(artifact, **changes)])
        with self.assertRaises(RuntimeError):
            source.validate_artifact([artifact, artifact])


class CredentialTests(unittest.TestCase):
    def test_api_key_has_priority_even_when_account_also_configured(self):
        values = {"NOTARY_API_KEY_BASE64": "fixture-key", "NOTARY_APPLE_ID": "fixture@example.test",
                  "NOTARY_APP_PASSWORD": "fixture-password"}
        self.assertEqual(notary.authentication_mode(values, "KEY", "ISSUER"), "api-key")

    def test_missing_api_key_uses_account_and_ignores_leftover_key_ids(self):
        values = {"NOTARY_API_KEY_BASE64": "", "NOTARY_APPLE_ID": "fixture@example.test",
                  "NOTARY_APP_PASSWORD": "fixture-password"}
        for key_id, issuer in (("", ""), ("OLDKEY", "OLDISSUER")):
            self.assertEqual(notary.authentication_mode(values, key_id, issuer), "apple-id")

    def test_partial_api_configuration_cannot_fall_back_to_account(self):
        values = {"NOTARY_API_KEY_BASE64": "fixture-key", "NOTARY_APPLE_ID": "fixture@example.test",
                  "NOTARY_APP_PASSWORD": "fixture-password"}
        for key_id, issuer in (("KEY", ""), ("", "ISSUER"), ("", "")):
            with self.assertRaisesRegex(RuntimeError, "not falling back"):
                notary.authentication_mode(values, key_id, issuer)

    def test_account_requires_both_email_and_app_password(self):
        for values in ({}, {"NOTARY_APPLE_ID": "fixture@example.test"},
                       {"NOTARY_APP_PASSWORD": "fixture"},
                       {"NOTARY_APPLE_ID": "  ", "NOTARY_APP_PASSWORD": "fixture"}):
            with self.assertRaisesRegex(RuntimeError, "not configured"):
                notary.authentication_mode(values, "", "")

    def test_both_modes_use_validated_profile_in_explicit_temporary_keychain(self):
        values = {"NOTARY_APPLE_ID": " fixture@example.test ", "NOTARY_APP_PASSWORD": "do-not-log"}
        keychain, key = Path("temporary.keychain-db"), Path("AuthKey.p8")
        for mode in ("api-key", "apple-id"):
            with patch.object(notary, "run") as run:
                auth = notary.store_profile(mode, keychain, key, values, "ABCDEFGHIJ", "KEY", "ISSUER")
            command = run.call_args.args[0]
            self.assertEqual(command[:4], ["xcrun", "notarytool", "store-credentials", notary.PROFILE])
            self.assertIn("--validate", command)
            self.assertNotIn("--sync", command)
            self.assertEqual(command[-3:-1], ["--keychain", keychain])
            self.assertEqual(auth, ["--keychain-profile", notary.PROFILE, "--keychain", keychain])
            self.assertNotIn("--password", auth)
            self.assertNotIn("do-not-log", auth)
            if mode == "apple-id":
                self.assertIn("fixture@example.test", command)
                self.assertIn("--team-id", command)
                self.assertNotIn("--key", command)
            else:
                self.assertIn("--key", command)
                self.assertNotIn("--apple-id", command)

    def test_account_preparation_does_not_create_p8(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(notary, "run"):
            directory = Path(temporary) / "private"
            values = {"SIGNING_CERTIFICATE_P12_BASE64": base64.b64encode(b"fixture-p12").decode(),
                      "SIGNING_CERTIFICATE_PASSWORD": "fixture", "NOTARY_API_KEY_BASE64": ""}
            keychain, key = notary.prepare(directory, values)
            self.assertIsNone(key)
            self.assertFalse((directory / "AuthKey.p8").exists())
            self.assertEqual(keychain, directory / "signing.keychain-db")

    def test_authentication_failure_stops_before_signing_and_cleans_up(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            env = {"RUNNER_TEMP": temporary,
                   "SIGNING_CERTIFICATE_P12_BASE64": "fixture-p12",
                   "SIGNING_CERTIFICATE_PASSWORD": "fixture-p12-password",
                   "NOTARY_API_KEY_BASE64": "fixture-key",
                   "NOTARY_APPLE_ID": "fixture@example.test", "NOTARY_APP_PASSWORD": "fixture-password"}
            with patch.dict(os.environ, env), \
                    patch.object(notary, "prepare", return_value=(root / "keychain", root / "key")), \
                    patch.object(notary, "cleanup") as cleanup, \
                    patch.object(notary.sign_app, "inventory"), patch.object(notary.sign_app, "verify_payload"), \
                    patch.object(notary.sign_app, "sign") as sign, \
                    patch.object(notary, "store_profile", side_effect=RuntimeError("Authentication failed")) as store:
                with self.assertRaisesRegex(RuntimeError, "Authentication failed"):
                    notary.notarize(root / "MacSW.app", root / "output", "ABCDEFGHIJ",
                                    "Developer ID Application: Fixture", "KEY", "ISSUER")
                self.assertEqual(store.call_count, 1)
                self.assertEqual(store.call_args.args[0], "api-key")
                sign.assert_not_called()
                cleanup.assert_called_once()
                self.assertFalse(any(name in os.environ for name in notary.SECRET_NAMES))

    def test_notarization_rejected_never_staples_or_produces_final_zip(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app = root / "MacSW.app"
            output = root / "output"
            commands = []
            env = {"RUNNER_TEMP": temporary, **{name: "fixture-secret" for name in notary.SECRET_NAMES}}
            def command(args, **kwargs):
                self.assertFalse(any(name in os.environ for name in notary.SECRET_NAMES))
                commands.append(args)
                return b"{}"
            with patch.dict(os.environ, env), patch.object(notary, "prepare", return_value=(root / "keychain", root / "key")), \
                    patch.object(notary, "cleanup") as cleanup, \
                    patch.object(notary.sign_app, "inventory"), patch.object(notary.sign_app, "verify_payload"), \
                    patch.object(notary.sign_app, "sign", return_value=[]), patch.object(notary.sign_app, "verify"), \
                    patch.object(notary, "run", side_effect=command), \
                    patch.object(notary.subprocess, "run", return_value=SimpleNamespace(
                        returncode=1, stdout=json.dumps({"id": "fixture-id", "status": "Invalid"}).encode())):
                with self.assertRaisesRegex(RuntimeError, "not Accepted"):
                    notary.notarize(app, output, "ABCDEFGHIJ", "Developer ID Application: Fixture", "KEY", "ISSUER")
                cleanup.assert_called_once()
                self.assertFalse(any("stapler" in args for args in commands))
                self.assertEqual(list(output.glob("*-signed.zip")), [])
                self.assertTrue((output / "notary-result.json").exists())

    def test_no_credentials_means_no_signing_or_files(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True), \
                patch.object(notary, "prepare") as prepare:
            with self.assertRaisesRegex(RuntimeError, "not configured"):
                notary.notarize(Path(directory) / "MacSW.app", Path(directory) / "output", "", "", "", "")
            prepare.assert_not_called()
            self.assertFalse((Path(directory) / "output").exists())

    def test_private_file_permissions_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture"
            notary.private_file(path, b"fake-key")
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                notary.private_file(path, b"new")

    def test_credential_commands_suppressed_and_no_allow_all_import(self):
        calls = []
        with tempfile.TemporaryDirectory() as directory, patch.object(notary, "run", side_effect=lambda cmd: calls.append(cmd)):
            root = Path(directory) / "private"
            values = {notary.SECRET_NAMES[0]: base64.b64encode(b"fixture-p12").decode(),
                      notary.SECRET_NAMES[1]: "never-log-this-password",
                      notary.SECRET_NAMES[2]: base64.b64encode(b"fixture-p8").decode()}
            keychain, key = notary.prepare(root, values)
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)
            self.assertFalse((root / "certificate.p12").exists())
            self.assertEqual(key.read_bytes(), b"fixture-p8")
            import_call = next(cmd for cmd in calls if cmd[1] == "import")
            self.assertNotIn("-A", import_call)
            self.assertIn("/usr/bin/codesign", import_call)

    def test_cleanup_scoped_known_files_only(self):
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, RUNNER_TEMP=temporary):
            directory = Path(temporary) / "macsw-signing-credentials"
            directory.mkdir()
            (directory / "AuthKey.p8").write_text("fixture")
            notary.cleanup(directory)
            self.assertFalse(directory.exists())
            with self.assertRaisesRegex(RuntimeError, "Refusing cleanup"):
                notary.cleanup(Path(temporary))
            directory.mkdir()
            unknown = directory / "user-data"
            unknown.write_text("preserve")
            with self.assertRaisesRegex(RuntimeError, "Unexpected entry"):
                notary.cleanup(directory)
            self.assertEqual(unknown.read_text(), "preserve")
            unknown.unlink()
            external = Path(temporary) / "other.keychain-db"
            external.write_text("preserve")
            (directory / "signing.keychain-db").symlink_to(external)
            with patch.object(notary.subprocess, "run") as run:
                with self.assertRaisesRegex(RuntimeError, "Unexpected entry"):
                    notary.cleanup(directory)
                run.assert_not_called()
            self.assertEqual(external.read_text(), "preserve")

    def test_command_failure_does_not_print_arguments_or_password(self):
        with patch.object(notary.subprocess, "run", return_value=type("Result", (), {"returncode": 1})()):
            with self.assertRaises(RuntimeError) as error:
                notary.run(["security", "import", "private", "-P", "never-print"])
            self.assertNotIn("never-print", str(error.exception))

    def test_signing_workflow_is_manual_protected_and_no_release(self):
        workflow = (PROJECT / ".github/workflows/sign-app.yml").read_text()
        self.assertIn("workflow_dispatch:", workflow)
        self.assertIn("environment: macsw-release", workflow)
        self.assertIn("github.ref == 'refs/heads/master'", workflow)
        self.assertNotIn("contents: write", workflow)
        self.assertNotIn("action-gh-release", workflow)
        self.assertNotIn("pull_request", workflow)
        self.assertNotIn("continue-on-error", workflow)
        self.assertLess(workflow.index("scripts/ci/signing-input.py"), workflow.index("secrets.SIGNING_CERTIFICATE"))
        self.assertIn("if: always()", workflow)
        self.assertIn("NOTARY_APPLE_ID: ${{ secrets.NOTARY_APPLE_ID || vars.NOTARY_APPLE_ID }}", workflow)
        self.assertIn("NOTARY_APP_PASSWORD: ${{ secrets.NOTARY_APP_PASSWORD }}", workflow)
        self.assertNotIn("vars.NOTARY_APP_PASSWORD", workflow)
        self.assertIn("NOTARY_API_KEY_BASE64: ${{ secrets.NOTARY_API_KEY_BASE64 }}", workflow)
        self.assertIn("NOTARY_KEY_ID: ${{ vars.NOTARY_KEY_ID }}", workflow)
        self.assertIn("NOTARY_ISSUER_ID: ${{ vars.NOTARY_ISSUER_ID }}", workflow)
        uploads = workflow.split("uses: actions/upload-artifact@v7")[1:]
        self.assertEqual(len(uploads), 2)
        for upload in uploads:
            self.assertNotIn("macsw-signing-credentials", upload)
            self.assertNotIn("notary-submission.zip", upload)
            self.assertNotIn("native-probes", upload)


if __name__ == "__main__":
    unittest.main()
