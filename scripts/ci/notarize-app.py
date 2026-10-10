"""Direct Distribution: temporary signing identity, checks, notarize, staple.

Called only by the protected manual job. No private credential is copied into
the App, output directory or logs. All secret command output is suppressed.
"""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import secrets
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT / "scripts"))
import sign_app

SECRET_NAMES = ("SIGNING_CERTIFICATE_P12_BASE64", "SIGNING_CERTIFICATE_PASSWORD",
                "NOTARY_API_KEY_BASE64", "NOTARY_APPLE_ID", "NOTARY_APP_PASSWORD")
PROFILE = "macsw-ci-notary"


def authentication_mode(values, key_id, issuer):
    if values.get("NOTARY_API_KEY_BASE64"):
        if not key_id or not issuer:
            raise RuntimeError("API key is configured but its Key ID / Issuer ID is missing; not falling back")
        return "api-key"
    if not values.get("NOTARY_APPLE_ID", "").strip() or not values.get("NOTARY_APP_PASSWORD"):
        raise RuntimeError("Signing/notarization credentials are not configured")
    return "apple-id"


def store_profile(mode, keychain, key, values, team, key_id, issuer):
    if mode == "api-key":
        credentials = ["--key", key, "--key-id", key_id, "--issuer", issuer]
    else:
        credentials = ["--apple-id", values["NOTARY_APPLE_ID"].strip(),
                       "--password", values["NOTARY_APP_PASSWORD"], "--team-id", team]
    # Validate before signing/probes. A configured but rejected API key must
    # fail, never silently use a different account. No iCloud keychain sync.
    run(["xcrun", "notarytool", "store-credentials", PROFILE,
         *credentials, "--keychain", keychain, "--validate"])
    return ["--keychain-profile", PROFILE, "--keychain", keychain]


def run(arguments, *, timeout=120):
    # Never use check=True here: CalledProcessError renders command arguments,
    # including keychain and P12 passwords, in a traceback.
    result = subprocess.run(list(map(str, arguments)), capture_output=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError("Distribution step failed: " + str(arguments[0]))
    return result.stdout


def private_file(path, data):
    with path.open("xb") as stream:
        os.chmod(path, 0o600)
        stream.write(data)


def cleanup(directory):
    # Only the fixed credential directory under RUNNER_TEMP is eligible.
    runner = Path(os.environ["RUNNER_TEMP"]).resolve()
    if (directory.name != "macsw-signing-credentials" or directory.parent.resolve() != runner
            or directory.is_symlink()):
        raise RuntimeError("Refusing cleanup outside the private signing directory")
    if not directory.exists():
        return
    paths = list(directory.iterdir())
    for path in paths:
        if (path.name not in ("certificate.p12", "AuthKey.p8", "signing.keychain-db")
                or path.is_symlink() or not path.is_file()):
            raise RuntimeError("Unexpected entry in signing credentials directory")
    keychain = directory / "signing.keychain-db"
    if keychain.exists():
        result = subprocess.run(["/usr/bin/security", "delete-keychain", str(keychain)],
                                capture_output=True, timeout=30)
        if result.returncode:
            raise RuntimeError("Unable to remove temporary signing keychain")
    # Refuse unknown entries rather than deleting a broad directory tree.
    for path in paths:
        if path.exists():
            path.unlink()
    directory.rmdir()


def prepare(directory, values):
    directory.mkdir(mode=0o700, exist_ok=False)
    keychain = directory / "signing.keychain-db"
    certificate = directory / "certificate.p12"
    key = None
    private_file(certificate, base64.b64decode(values[SECRET_NAMES[0]], validate=True))
    if values.get("NOTARY_API_KEY_BASE64"):
        key = directory / "AuthKey.p8"
        private_file(key, base64.b64decode(values["NOTARY_API_KEY_BASE64"], validate=True))
    password = secrets.token_urlsafe(32)
    run(["/usr/bin/security", "create-keychain", "-p", password, keychain])
    run(["/usr/bin/security", "set-keychain-settings", "-lut", "21600", keychain])
    run(["/usr/bin/security", "unlock-keychain", "-p", password, keychain])
    run(["/usr/bin/security", "import", certificate, "-P", values[SECRET_NAMES[1]],
         "-k", keychain, "-t", "cert", "-f", "pkcs12", "-T", "/usr/bin/codesign"])
    run(["/usr/bin/security", "set-key-partition-list", "-S", "apple-tool:,apple:",
         "-s", "-k", password, keychain])
    certificate.unlink()
    return keychain, key


def notarize(app, output, team, identity, key_id="", issuer=""):
    values = {name: os.environ.pop(name, "") for name in SECRET_NAMES}
    if not all(values[name] for name in SECRET_NAMES[:2]) or not all((team, identity)):
        raise RuntimeError("Signing/notarization credentials are not configured")
    mode = authentication_mode(values, key_id, issuer)
    directory = Path(os.environ["RUNNER_TEMP"]).resolve() / "macsw-signing-credentials"
    if directory.exists() or directory.is_symlink():
        raise RuntimeError("A previous credentials directory needs explicit cleanup")
    sign_app.inventory(app)
    sign_app.verify_payload(app)
    output.mkdir(parents=True, exist_ok=False)
    try:
        keychain, key = prepare(directory, values)
        auth = store_profile(mode, keychain, key, values, team, key_id, issuer)
        values.clear()
        print("Notarization authentication validated: " + mode, flush=True)
        entries = sign_app.sign(app, identity, team, keychain, PROJECT / "resources/signing")
        (output / "signing-inventory.json").write_text(json.dumps(entries, indent=2) + "\n")
        # Check actual native Python imports and a libffi callback, with no
        # user-site / bytecode writes inside the now sealed bundle.
        python = app / "Contents/Resources/SWCLI/runtime/PythonNative/bin/python3.11"
        run([python, "-I", "-B", "-c", "import ctypes, ssl, jsonschema, rpds; "
             "f=ctypes.CFUNCTYPE(ctypes.c_int,ctypes.c_int)(lambda x:x+1); "
             "assert f(41)==42; print('NATIVE_PYTHON_SIGNED_PASS')"])
        run([app / "Contents/MacOS/7zz", "i"])
        run([sys.executable, "-B", PROJECT / "scripts/ci/verify-toolbox-native.py",
             "--app", app, "--evidence", output / "native-probes"], timeout=1200)
        # Runtime probes must not have mutated the signed bundle.
        sign_app.verify(app, team)
        submission = output / "notary-submission.zip"
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, submission], timeout=600)
        result = subprocess.run(list(map(str, ["xcrun", "notarytool", "submit", submission,
                                *auth, "--wait", "--timeout", "20m", "--output-format", "json"])),
                                capture_output=True, timeout=1500)
        try:
            response = json.loads(result.stdout)
        except ValueError:
            raise RuntimeError("Notary service did not return a JSON result") from None
        (output / "notary-result.json").write_text(json.dumps(response, indent=2) + "\n")
        if response.get("id"):
            log = run(["xcrun", "notarytool", "log", response["id"], *auth])
            (output / "notary-log.json").write_bytes(log)
        if result.returncode or response.get("status") != "Accepted":
            raise RuntimeError("Notarization was not Accepted; final ZIP was not produced")
        run(["xcrun", "stapler", "staple", app])
        run(["xcrun", "stapler", "validate", app])
        sign_app.verify(app, team)
        run(["/usr/sbin/spctl", "--assess", "--type", "execute", "--verbose=2", app])
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        version = info["CFBundleShortVersionString"]
        import re
        if not re.fullmatch(r"[A-Za-z0-9._-]+", version):
            raise RuntimeError("Unsafe App version")
        final = output / ("MacSW-" + version + "-macOS-signed.zip")
        run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, final], timeout=600)
        (output / (final.name + ".sha256")).write_text(sign_app.digest(final) + "  " + final.name + "\n")
        submission.unlink()
        print("Developer ID checks, runtime primitives, notarization and stapling passed.")
    finally:
        values.clear()
        failed = sys.exc_info()[0] is not None
        try:
            cleanup(directory)
        except Exception:
            if not failed:
                raise
            print("Credential cleanup failed; original distribution error preserved.", file=sys.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--cleanup", action="store_true")
    args = parser.parse_args()
    try:
        if args.cleanup:
            cleanup(Path(os.environ["RUNNER_TEMP"]).resolve() / "macsw-signing-credentials")
        elif not args.app or not args.output:
            parser.error("--app and --output are required")
        else:
            notarize(args.app, args.output, os.environ.get("SIGNING_TEAM_ID", ""),
                     os.environ.get("SIGNING_IDENTITY", ""), os.environ.get("NOTARY_KEY_ID", ""),
                     os.environ.get("NOTARY_ISSUER_ID", ""))
    except Exception as error:
        # Some subprocess/decoding exceptions include secret input bytes or
        # argument arrays. Only our explicitly sanitized errors are displayed.
        print(str(error) if isinstance(error, RuntimeError) else "Distribution operation failed (details suppressed).",
              file=sys.stderr)
        sys.exit(1)
