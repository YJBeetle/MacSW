"""Publish original signed, notarized and bootstrap-verified CI assets.

Tagged candidates bind both native profiles and their own immutable source
version; later master progress does not relabel them. Manual signing keeps the
original release-only source-drift guard. Never rebuild, re-sign or clobber.
"""
import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

PROJECT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('signing_input', PROJECT / 'scripts/ci/signing-input.py')
signing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(signing)
REPOSITORY = signing.REPOSITORY
ROOT = f'repos/{REPOSITORY}'
NAMESPACE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
RELEASE_ONLY = {'.github/workflows/publish-release.yml', 'scripts/ci/publish-release.py',
                'scripts/tests/test_publish_release.py', 'docs/direct-distribution.md'}
JSON_FILES = ('provenance.json', 'signing-inventory.json', 'notary-result.json', 'notary-log.json')


def run(args, **kwargs):
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def api(route, *, body=None, optional=False, method=None):
    args = ['gh', 'api', route]
    data = None
    if body is not None:
        args += ['--method', method or 'POST', '--input', '-']
        data = json.dumps(body).encode()
    result = subprocess.run(args, input=data, capture_output=True, timeout=90)
    if optional and result.returncode and b'(HTTP 404)' in result.stderr:
        return None
    if result.returncode:
        raise RuntimeError(f'GitHub request failed: {route}')
    return json.loads(result.stdout)


def collection(route, key):
    result = api(route + '?per_page=100')
    if result['total_count'] != len(result[key]):
        raise RuntimeError(f'Unexpected pagination: {route}')
    return result[key]


def digest(path):
    with path.open('rb') as stream:
        return stream_digest(stream)


def stream_digest(stream):
    value = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b''):
        value.update(chunk)
    return value.hexdigest()


def select_artifact(items, name, run_id, sha):
    matches = [item for item in items if item['name'] == name]
    if len(matches) != 1:
        raise RuntimeError(f'Exactly one {name} artifact is required')
    item = matches[0]
    if (item.get('expired') is not False or
            not re.fullmatch(r'sha256:[0-9a-f]{64}', item.get('digest') or '') or
            item.get('workflow_run', {}).get('id') != int(run_id) or
            item.get('workflow_run', {}).get('head_sha') != sha):
        raise RuntimeError('Untrusted, expired or unbound artifact')
    return item


def fetch_artifact(item, path):
    with path.open('xb') as output:
        run(['gh', 'api', f"{ROOT}/actions/artifacts/{item['id']}/zip"], stdout=output, timeout=900)
    if 'sha256:' + digest(path) != item['digest']:
        raise RuntimeError('Artifact service digest mismatch; nothing extracted')


def validate_signing_run(record, jobs):
    if (record.get('path') != '.github/workflows/sign-app.yml' or
            record.get('head_branch') != 'master' or record.get('event') not in ('workflow_dispatch', 'workflow_run') or
            record.get('status') != 'completed' or record.get('conclusion') != 'success' or
            record.get('repository', {}).get('full_name') != REPOSITORY or
            record.get('head_repository', {}).get('full_name') != REPOSITORY or
            not re.fullmatch(r'[0-9a-f]{40}', record.get('head_sha', '')) or
            len(jobs) not in (2, 3) or len({j['name'] for j in jobs}) != len(jobs)
            or {j['name'] for j in jobs} not in
                ({'sign-and-notarize', 'verify-signed-bootstrap'},
                 {'verify-source', 'sign-and-notarize', 'verify-signed-bootstrap'})
            or (record.get('event') == 'workflow_run' and len(jobs) != 3) or
            any(j['conclusion'] != 'success' for j in jobs)):
        raise RuntimeError('Both trusted signing and macOS 15 bootstrap jobs must pass')


def validate_release_changes(paths):
    for path in paths:
        if path not in RELEASE_ONLY and not (path.startswith('docs/releases/') and path.endswith('.md')):
            raise RuntimeError(f'Payload changed after signing: {path}; rebuild and sign first')


def publisher_matches(sha):
    current = os.environ['GITHUB_SHA']
    run(['git', 'merge-base', '--is-ancestor', sha, current])
    changed = subprocess.check_output(['git', 'diff', '--name-only', sha, current], text=True).splitlines()
    validate_release_changes(changed)


def versions():
    return dict(re.findall(r'^([A-Z0-9_]+)="([^"\n]+)"$',
                          (PROJECT / 'config/versions.env').read_text(), re.M))


def unpack_candidate(path, destination, version):
    archive = f'MacSW-{version}-macOS-signed.zip'
    expected = {archive, archive + '.sha256', 'appcast.xml', *JSON_FILES}
    with zipfile.ZipFile(path) as bundle:
        if len(bundle.namelist()) != len(expected) or set(bundle.namelist()) != expected:
            raise RuntimeError('Unexpected signing candidate members')
        destination.mkdir()
        for name in sorted(expected):
            with bundle.open(name) as source, (destination / name).open('xb') as target:
                shutil.copyfileobj(source, target)
    return destination / archive


def verify_feed(candidate, archive, info):
    tree = ET.fromstring((candidate / 'appcast.xml').read_bytes())
    items = tree.findall('./channel/item')
    if len(items) != 1:
        raise RuntimeError('Expected one stable update item')
    item = items[0]
    enclosure = item.find('enclosure')
    version = info['CFBundleShortVersionString']
    expected = {'url': f'https://github.com/{REPOSITORY}/releases/download/v{version}/{archive.name}',
                'length': str(archive.stat().st_size), 'type': 'application/octet-stream'}
    if (any(enclosure.get(k) != v for k, v in expected.items()) or
            item.findtext(NAMESPACE + 'version') != info['CFBundleVersion'] or
            item.findtext(NAMESPACE + 'shortVersionString') != version or
            item.findtext(NAMESPACE + 'minimumSystemVersion') != info['LSMinimumSystemVersion']):
        raise RuntimeError('Update feed does not bind this final archive and version')
    key = base64.b64decode(info['SUPublicEDKey'], validate=True)
    signature = base64.b64decode(enclosure.get(NAMESPACE + 'edSignature', ''), validate=True)
    if len(key) != 32 or len(signature) != 64:
        raise RuntimeError('Invalid Ed25519 public metadata')
    # RFC 8410 SubjectPublicKeyInfo, Ed25519 OID 1.3.101.112. Only public data.
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        (root / 'public.der').write_bytes(bytes.fromhex('302a300506032b6570032100') + key)
        (root / 'signature').write_bytes(signature)
        run(['openssl', 'pkeyutl', '-verify', '-pubin', '-keyform', 'DER', '-rawin',
             '-inkey', root / 'public.der', '-in', archive, '-sigfile', root / 'signature'], timeout=120)


def validate_candidate(candidate, archive, values, sha, *, source_public_key=None):
    version = values['APP_VERSION']
    if (candidate / (archive.name + '.sha256')).read_text().split() != [digest(archive), archive.name]:
        raise RuntimeError('Final archive checksum mismatch')
    result = json.loads((candidate / 'notary-result.json').read_text())
    log = json.loads((candidate / 'notary-log.json').read_text())
    if result.get('status') != 'Accepted' or log.get('status') != 'Accepted' or result.get('id') != log.get('jobId') or log.get('issues'):
        raise RuntimeError('Apple notarization was not accepted')
    signing.validate_app_zip(archive)
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read('MacSW.app/Contents/Info.plist'))
        manifest = plistlib.loads(bundle.read('MacSW.app/Contents/Resources/BuildManifest.plist'))
        if (info['CFBundleShortVersionString'] != version or info['CFBundleVersion'] != values['APP_BUILD'] or
                manifest['SWCLIVersion'] != values['SWCLI_VERSION'] or
                manifest['SWCLISourceCommit'] != values['SWCLI_SOURCE_COMMIT'] or
                info['SUPublicEDKey'] != (source_public_key if source_public_key is not None else
                                           (PROJECT / 'config/sparkle-public-key.txt').read_text().strip()) or
                info['SUFeedURL'] != f'https://github.com/{REPOSITORY}/releases/latest/download/appcast.xml'):
            raise RuntimeError('Candidate identity differs from the reviewed source')
    provenance = json.loads((candidate / 'provenance.json').read_text())
    tag_release = provenance.get('release_tag')
    runtime_result = ('visible-smoke-and-hidden-full-passed' if tag_release else 'visible-smoke-passed')
    if (provenance.get('repository') != REPOSITORY or provenance.get('source_commit') != sha or
            (tag_release and tag_release != 'v' + version) or
            provenance.get('runtime_verification') != {'required': True, 'result': runtime_result}):
        raise RuntimeError('Candidate did not pass the required visible smoke at this source')
    verify_feed(candidate, archive, info)
    return provenance, result['id']


def prepare_assets(candidate, archive, build_zip, provenance, values, destination):
    destination.mkdir()
    for path in (archive, candidate / 'appcast.xml'):
        shutil.copyfile(path, destination / path.name)
    sources = {'wine-' + values['WINE_VERSION'] + '.tar.xz': values['WINE_SOURCE_SHA256'],
               'mono-' + values['MONO_SOURCE_COMMIT'] + '.tar.gz': values['MONO_SOURCE_SHA256']}
    with zipfile.ZipFile(build_zip) as bundle:
        with bundle.open(provenance['app_archive']) as stream:
            if stream_digest(stream) != provenance['app_sha256']:
                raise RuntimeError('Original unsigned build does not match signing provenance')
        for name, sha in sources.items():
            with bundle.open('dist/' + name) as source, (destination / name).open('xb') as target:
                shutil.copyfileobj(source, target)
            if digest(destination / name) != sha:
                raise RuntimeError('Source archive checksum mismatch')
    # Fixed metadata and stored entries make retries byte-for-byte deterministic.
    with zipfile.ZipFile(destination / 'release-info.zip', 'w') as bundle:
        for name in JSON_FILES:
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            bundle.writestr(entry, (candidate / name).read_bytes())
    checksums = ''.join(f'{digest(p)}  {p.name}\n' for p in sorted(destination.iterdir()))
    (destination / 'SHA256SUMS').write_text(checksums)
    return {p.name: {'sha256': digest(p), 'size': p.stat().st_size} for p in destination.iterdir()}


def release_for_tag(tag):
    # GitHub's /releases/tags/{tag} lookup only returns published releases.
    # The authenticated list also contains drafts, including a resumable upload.
    matches = [release for release in api(f'{ROOT}/releases?per_page=100')
               if release['tag_name'] == tag]
    if len(matches) > 1:
        raise RuntimeError('Multiple releases use the requested tag')
    return matches[0] if matches else None


def verify_uploaded(release, expected):
    assets = release['assets']
    if len(assets) != len(expected) or {a['name'] for a in assets} != set(expected):
        raise RuntimeError('Release asset set differs from the verified six files')
    for asset in assets:
        value = expected[asset['name']]
        if asset['size'] != value['size'] or asset.get('digest') != 'sha256:' + value['sha256']:
            raise RuntimeError(f"Uploaded asset digest mismatch: {asset['name']}")


def verify_public(release, expected):
    for asset in release['assets']:
        request = urllib.request.Request(asset['browser_download_url'], headers={'User-Agent': 'MacSW-release-verifier'})
        with urllib.request.urlopen(request, timeout=180) as response:
            actual = stream_digest(response)
        if actual != expected[asset['name']]['sha256']:
            raise RuntimeError(f"Anonymous public download mismatch: {asset['name']}")


def ensure_newer_release(latest, values):
    if latest is None or latest['tag_name'] == 'v' + values['APP_VERSION']:
        return
    previous = latest['tag_name'].removeprefix('v')
    if (not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', previous) or
            tuple(map(int, previous.split('.'))) >= tuple(map(int, values['APP_VERSION'].split('.')))):
        raise RuntimeError('Refusing to publish an older version as latest')
    feeds = [asset for asset in latest['assets'] if asset['name'] == 'appcast.xml']
    if len(feeds) != 1:
        raise RuntimeError('Previous update feed is missing; cannot verify build ordering')
    request = urllib.request.Request(feeds[0]['browser_download_url'], headers={'User-Agent': 'MacSW-release-verifier'})
    with urllib.request.urlopen(request, timeout=60) as response:
        tree = ET.fromstring(response.read(1024 * 1024))
    builds = tree.findall('./channel/item/' + NAMESPACE + 'version')
    if (len(builds) != 1 or not re.fullmatch(r'[1-9][0-9]*', builds[0].text or '') or
            int(builds[0].text) >= int(values['APP_BUILD'])):
        raise RuntimeError('New Sparkle build number must increase')


def candidate_source(record, candidate_zip):
    # workflow_run's head SHA is default-branch workflow code. The signed payload
    # source is carried in the hash-bound candidate and checked again below.
    with zipfile.ZipFile(candidate_zip) as bundle:
        if bundle.namelist().count('provenance.json') != 1:
            raise RuntimeError('Missing or duplicate signing source provenance')
        source = json.loads(bundle.read('provenance.json'))
    sha, release_tag = source.get('source_commit', ''), source.get('release_tag')
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise RuntimeError('Invalid signed source SHA')
    if record['event'] == 'workflow_run':
        if not release_tag:
            raise RuntimeError('Automatic signing must bind a verified version tag')
        signing.policy.validate_tag(release_tag, sha)
    elif sha != record["head_sha"] or release_tag:
        raise RuntimeError('Manual signing source differs from its exact master run')
    return sha, release_tag


def publication_source(sha, release_tag):
    if release_tag:
        signing.policy.validate_tag(release_tag, sha)
        values = signing.policy.source_versions(sha)
        public_key = signing.policy.git("show", sha + ":config/sparkle-public-key.txt").strip()
        # Full acceptance is long-running; later master payload changes do not
        # relabel an already verified immutable tagged candidate.
        try:
            notes = signing.policy.git("show", sha + ":docs/releases/" + release_tag + ".md")
        except subprocess.CalledProcessError:
            notes = None
        return values, public_key, notes
    publisher_matches(sha)
    return versions(), None, None


def publish(signing_run_id, output):
    if (os.environ.get('GITHUB_REPOSITORY') != REPOSITORY or
            os.environ.get('GITHUB_REF') != 'refs/heads/master' or
            os.environ.get('GITHUB_EVENT_NAME') not in ('workflow_dispatch', 'workflow_run') or
            not re.fullmatch(r'[1-9][0-9]*', signing_run_id)):
        raise RuntimeError('Publication is restricted to trusted master CI')
    output.mkdir(parents=True, exist_ok=False)
    record = api(f'{ROOT}/actions/runs/{signing_run_id}')
    jobs = collection(f'{ROOT}/actions/runs/{signing_run_id}/jobs', 'jobs')
    validate_signing_run(record, jobs)
    signing_sha = record['head_sha']
    artifact = select_artifact(collection(f'{ROOT}/actions/runs/{signing_run_id}/artifacts', 'artifacts'),
                               'MacSW-Developer-ID-candidate', signing_run_id, signing_sha)
    candidate_zip = output / 'candidate-artifact.zip'
    fetch_artifact(artifact, candidate_zip)
    sha, release_tag = candidate_source(record, candidate_zip)
    values, source_public_key, source_notes = publication_source(sha, release_tag)
    if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', values['APP_VERSION']) or not re.fullmatch(r'[1-9][0-9]*', values['APP_BUILD']):
        raise RuntimeError('Invalid stable version/build')
    tag = 'v' + values['APP_VERSION']
    candidate = output / 'candidate'
    archive = unpack_candidate(candidate_zip, candidate, values['APP_VERSION'])
    provenance, notary_id = validate_candidate(candidate, archive, values, sha, source_public_key=source_public_key)
    build_id = str(provenance['build_run_id'])
    build = api(f'{ROOT}/actions/runs/{build_id}')
    signing.validate_run(build, sha, release_tag=release_tag)
    signing.validate_jobs(collection(f'{ROOT}/actions/runs/{build_id}/jobs', 'jobs'), release_tag=release_tag)
    if release_tag:
        actual_profiles = signing.runtime_proofs(
            collection(f'{ROOT}/actions/runs/{build_id}/artifacts', 'artifacts'), output, build_id, sha,
            plan=signing.source_runtime_plan(sha))
        if provenance.get('runtime_profiles') != actual_profiles:
            raise RuntimeError('Runtime profile proofs differ from signing provenance')
    original = select_artifact(collection(f'{ROOT}/actions/runs/{build_id}/artifacts', 'artifacts'),
                               'MacSW-macOS-App', build_id, sha)
    if original['id'] != provenance['artifact_id'] or original['digest'] != provenance['artifact_digest']:
        raise RuntimeError('Signing provenance refers to another build artifact')
    build_zip = output / 'build-artifact.zip'
    fetch_artifact(original, build_zip)
    assets = output / 'assets'
    expected = prepare_assets(candidate, archive, build_zip, provenance, values, assets)
    notes = PROJECT / f'docs/releases/{tag}.md'
    body = (source_notes if release_tag else notes.read_text() if notes.exists() else None) or f'MacSW {values["APP_VERSION"]} · build {values["APP_BUILD"]}\n\nSource: {sha}\nSWCLI: {values["SWCLI_VERSION"]}\n\nDeveloper ID signed and notarized. See SHA256SUMS and release-info.zip.'
    if api(f'{ROOT}/git/ref/heads/master')['object']['sha'] != os.environ['GITHUB_SHA']:
        raise RuntimeError('Master advanced during publication; use its current reviewed workflow')
    ensure_newer_release(api(f'{ROOT}/releases/latest', optional=True), values)
    existing_tag = api(f'{ROOT}/git/ref/tags/{tag}', optional=True)
    if existing_tag is None:
        if release_tag:
            raise RuntimeError('Verified version tag disappeared; refusing to recreate it')
        api(f'{ROOT}/git/refs', body={'ref': 'refs/tags/' + tag, 'sha': sha})
    else:
        target = existing_tag['object']
        for _ in range(8):
            if target['type'] == 'commit':
                break
            if target['type'] != 'tag':
                raise RuntimeError('Release tag does not identify a commit')
            target = api(f"{ROOT}/git/tags/{target['sha']}")['object']
        if target['type'] != 'commit' or target['sha'] != sha:
            raise RuntimeError('Release tag already points to another commit; refusing to move it')
    release = release_for_tag(tag)
    if release is None:
        latest = api(f'{ROOT}/releases/latest', optional=True)
        if latest and tuple(map(int, latest['tag_name'].removeprefix('v').split('.'))) >= tuple(map(int, values['APP_VERSION'].split('.'))):
            raise RuntimeError('Refusing to publish an older version as latest')
        release = api(f'{ROOT}/releases', body={'tag_name': tag, 'target_commitish': sha,
                    'name': 'MacSW ' + values['APP_VERSION'], 'body': body, 'draft': True,
                    'prerelease': False, 'make_latest': 'false'})
    if release['tag_name'] != tag or release['prerelease']:
        raise RuntimeError('Unexpected release identity or prerelease state')
    if release['draft']:
        for item in release['assets']:
            value = expected.get(item['name'])
            if value is None or item['size'] != value['size'] or item.get('digest') != 'sha256:' + value['sha256']:
                raise RuntimeError('Existing draft contains unexpected assets; refusing to overwrite')
        names = {a['name'] for a in release['assets']}
        missing = [assets / name for name in sorted(expected) if name not in names]
        if missing:
            run(['gh', 'release', 'upload', tag, '--repo', REPOSITORY, *missing], timeout=900)
        release = api(f"{ROOT}/releases/{release['id']}")
        verify_uploaded(release, expected)
        release = api(f"{ROOT}/releases/{release['id']}", body={'draft': False, 'make_latest': 'false'}, method='PATCH')
    verify_uploaded(release, expected)
    verify_public(release, expected)
    latest = api(f'{ROOT}/releases/latest', optional=True)
    if latest and tuple(map(int, latest['tag_name'].removeprefix('v').split('.'))) > tuple(map(int, values['APP_VERSION'].split('.'))):
        raise RuntimeError('A newer Release is already latest; refusing to downgrade')
    api(f"{ROOT}/releases/{release['id']}", body={'make_latest': 'true'}, method='PATCH')
    if api(f'{ROOT}/releases/latest')['tag_name'] != tag:
        raise RuntimeError('Latest release did not update')
    receipt = {'tag': tag, 'source_commit': sha, 'publisher_commit': os.environ['GITHUB_SHA'],
               'build_run_id': build_id, 'signing_run_id': signing_run_id, 'notary_id': notary_id,
               'assets': expected, 'anonymous_downloads_verified': True, 'latest': True,
               'url': release['html_url']}
    (output / 'public-verified.json').write_text(json.dumps(receipt, indent=2) + '\n')
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as stream:
            stream.write(f"Published [{tag}]({release['html_url']}); six original assets and anonymous download hashes verified.\n")
    print(json.dumps(receipt, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--signing-run-id', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    publish(args.signing_run_id, args.output)
