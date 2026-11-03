"""Release guards stay offline; these tests never publish or read credentials."""
import base64
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('publisher', ROOT / 'scripts/ci/publish-release.py')
publisher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publisher)


class PublicationTests(unittest.TestCase):
    def test_only_complete_trusted_signing_and_bootstrap_can_publish(self):
        record = {'path': '.github/workflows/sign-app.yml', 'head_branch': 'master',
                  'event': 'workflow_dispatch', 'status': 'completed', 'conclusion': 'success',
                  'repository': {'full_name': 'YJBeetle/MacSW'},
                  'head_repository': {'full_name': 'YJBeetle/MacSW'}, 'head_sha': 'a' * 40}
        jobs = [{'name': name, 'conclusion': 'success'} for name in ('sign-and-notarize', 'verify-signed-bootstrap')]
        publisher.validate_signing_run(record, jobs)
        for field, value in [('head_branch', 'feature'), ('event', 'pull_request'),
                             ('path', '.github/workflows/build-app.yml'), ('status', 'in_progress'),
                             ('conclusion', 'failure'), ('head_repository', {'full_name': 'fork/MacSW'})]:
            with self.subTest(field=field), self.assertRaises(RuntimeError):
                publisher.validate_signing_run(dict(record, **{field: value}), jobs)
        for invalid in [jobs[:1], jobs + jobs[:1], [dict(jobs[0]), dict(jobs[1], conclusion='skipped')]]:
            with self.assertRaises(RuntimeError):
                publisher.validate_signing_run(record, invalid)

    def test_publication_only_changes_do_not_waive_app_input_identity(self):
        publisher.validate_release_changes(['.github/workflows/publish-release.yml',
            'scripts/ci/publish-release.py', 'scripts/tests/test_publish_release.py',
            'docs/direct-distribution.md', 'docs/releases/v0.1.8.md'])
        for path in ['scripts/swcli/sw-cli', 'macos/Bootstrap/Sources/MacSWApp/Main.swift',
                     'scripts/package_app.sh', 'config/versions.env', 'Dependencies/SWCLI',
                     'patches/wine-crossover/0018-shell32-disable-host-menu-builder.patch',
                     '.github/workflows/sign-app.yml', '.github/workflows/build-app.yml']:
            with self.subTest(path=path), self.assertRaises(RuntimeError):
                publisher.validate_release_changes([path])

    def test_artifacts_must_bind_same_run_and_commit_with_service_hash(self):
        item = {'id': 7, 'name': 'candidate', 'expired': False, 'digest': 'sha256:' + 'b' * 64,
                'workflow_run': {'id': 12, 'head_sha': 'a' * 40}}
        self.assertEqual(publisher.select_artifact([item], 'candidate', '12', 'a' * 40), item)
        for changes in [{'expired': True}, {'digest': None}, {'workflow_run': {'id': 13, 'head_sha': 'a' * 40}},
                        {'workflow_run': {'id': 12, 'head_sha': 'c' * 40}}]:
            with self.assertRaises(RuntimeError):
                publisher.select_artifact([dict(item, **changes)], 'candidate', '12', 'a' * 40)
        with self.assertRaises(RuntimeError):
            publisher.select_artifact([item, item], 'candidate', '12', 'a' * 40)

    def test_bad_download_hash_is_rejected_before_any_extraction(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'artifact.zip'
            def download(args, stdout, timeout):
                stdout.write(b'untrusted download')
            with patch.object(publisher, 'run', side_effect=download), self.assertRaises(RuntimeError):
                publisher.fetch_artifact({'id': 7, 'digest': 'sha256:' + 'a' * 64}, path)
            self.assertEqual(list(path.parent.iterdir()), [path])

    def test_draft_lookup_resumes_existing_release_without_creating_duplicates(self):
        draft = {'id': 12, 'tag_name': 'v0.1.8', 'draft': True}
        other = {'id': 11, 'tag_name': 'v0.1.7', 'draft': False}
        with patch.object(publisher, 'api', return_value=[draft, other]) as request:
            self.assertEqual(publisher.release_for_tag('v0.1.8'), draft)
            request.assert_called_once_with(publisher.ROOT + '/releases?per_page=100')
        with patch.object(publisher, 'api', return_value=[other]):
            self.assertIsNone(publisher.release_for_tag('v0.1.8'))
        with patch.object(publisher, 'api', return_value=[draft, draft]), self.assertRaises(RuntimeError):
            publisher.release_for_tag('v0.1.8')

    def test_service_asset_receipts_require_exact_set_size_and_digest(self):
        expected = {'app.zip': {'sha256': 'a' * 64, 'size': 3}}
        release = {'assets': [{'name': 'app.zip', 'size': 3, 'digest': 'sha256:' + 'a' * 64}]}
        publisher.verify_uploaded(release, expected)
        for changes in [{'size': 4}, {'digest': None}, {'name': 'foreign.zip'}]:
            with self.assertRaises(RuntimeError):
                publisher.verify_uploaded({'assets': [dict(release['assets'][0], **changes)]}, expected)
        with self.assertRaises(RuntimeError):
            publisher.verify_uploaded({'assets': release['assets'] * 2}, expected)

    def test_public_downloads_use_no_authentication_and_verify_bytes(self):
        asset = {'name': 'file', 'browser_download_url': 'https://github.com/YJBeetle/MacSW/releases/download/v1/file'}
        expected = {'file': {'sha256': hashlib.sha256(b'correct').hexdigest()}}
        def urlopen(request, timeout):
            self.assertNotIn('Authorization', request.headers)
            return io.BytesIO(b'correct')
        with patch.object(publisher.urllib.request, 'urlopen', side_effect=urlopen):
            publisher.verify_public({'assets': [asset]}, expected)
        with patch.object(publisher.urllib.request, 'urlopen', return_value=io.BytesIO(b'changed')), self.assertRaises(RuntimeError):
            publisher.verify_public({'assets': [asset]}, expected)

    def test_candidate_rejects_path_traversal_and_unexpected_members(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'bad.zip'
            with zipfile.ZipFile(archive, 'w') as bundle:
                bundle.writestr('../outside', b'no')
            with self.assertRaises(RuntimeError):
                publisher.unpack_candidate(archive, root / 'candidate', '0.1.8')
            self.assertFalse((root / 'candidate').exists())

    def test_feed_binds_url_build_version_length_before_verifying_signature(self):
        update_spec = importlib.util.spec_from_file_location('feed', ROOT / 'scripts/ci/update-feed.py')
        update = importlib.util.module_from_spec(update_spec)
        update_spec.loader.exec_module(update)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / 'MacSW-0.1.8-macOS-signed.zip'
            archive.write_bytes(b'original')
            info = {'CFBundleShortVersionString': '0.1.8', 'CFBundleVersion': '10',
                    'LSMinimumSystemVersion': '13.0', 'SUPublicEDKey': base64.b64encode(b'k' * 32).decode()}
            good = update.create_feed(info, archive.name, 8, base64.b64encode(b's' * 64).decode())
            (root / 'appcast.xml').write_bytes(good)
            with patch.object(publisher, 'run') as verify:
                publisher.verify_feed(root, archive, info)
                self.assertIn('-pubin', verify.call_args.args[0])
                self.assertIn('-rawin', verify.call_args.args[0])
            for old, new in [(b'length="8"', b'length="9"'), (b'<sparkle:version>10', b'<sparkle:version>9'),
                             (b'/download/v0.1.8/', b'/download/v0.1.7/')]:
                (root / 'appcast.xml').write_bytes(good.replace(old, new))
                with patch.object(publisher, 'run') as verify, self.assertRaises(RuntimeError):
                    publisher.verify_feed(root, archive, info)
                verify.assert_not_called()

    def test_packaging_is_deterministic_and_does_not_change_original_app(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidate = root / 'candidate'
            candidate.mkdir()
            app = candidate / 'MacSW-0.1.8-macOS-signed.zip'
            app.write_bytes(b'signed original')
            (candidate / 'appcast.xml').write_bytes(b'feed')
            for name in publisher.JSON_FILES:
                (candidate / name).write_bytes(b'{"public":true}\n')
            sources = {'wine-11.16.tar.xz': b'wine source', 'mono-' + 'a' * 40 + '.tar.gz': b'mono source'}
            build = root / 'build.zip'
            with zipfile.ZipFile(build, 'w') as bundle:
                bundle.writestr('build/app.zip', b'unsigned original')
                for name, data in sources.items():
                    bundle.writestr('dist/' + name, data)
            provenance = {'app_archive': 'build/app.zip', 'app_sha256': hashlib.sha256(b'unsigned original').hexdigest()}
            values = {'WINE_VERSION': '11.16', 'MONO_SOURCE_COMMIT': 'a' * 40,
                      'WINE_SOURCE_SHA256': hashlib.sha256(b'wine source').hexdigest(),
                      'MONO_SOURCE_SHA256': hashlib.sha256(b'mono source').hexdigest()}
            first = publisher.prepare_assets(candidate, app, build, provenance, values, root / 'first')
            second = publisher.prepare_assets(candidate, app, build, provenance, values, root / 'second')
            self.assertEqual(first, second)
            self.assertEqual(len(first), 6)
            self.assertEqual(app.read_bytes(), b'signed original')
            self.assertEqual((root / 'first' / app.name).read_bytes(), app.read_bytes())
            self.assertNotIn(app.name + '.sha256', first)
            with zipfile.ZipFile(root / 'first/release-info.zip') as bundle:
                self.assertEqual(bundle.namelist(), list(publisher.JSON_FILES))

    def test_build_number_and_version_cannot_regress(self):
        values = {'APP_VERSION': '0.1.8', 'APP_BUILD': '10'}
        latest = {'tag_name': 'v0.1.7', 'assets': [{'name': 'appcast.xml', 'browser_download_url': 'https://github.com/fixture'}]}
        def feed(build):
            return io.BytesIO(('<rss xmlns:s="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>'
                              '<s:version>' + build + '</s:version></item></channel></rss>').encode())
        with patch.object(publisher.urllib.request, 'urlopen', return_value=feed('9')):
            publisher.ensure_newer_release(latest, values)
        for build in ['10', '11', 'invalid']:
            with patch.object(publisher.urllib.request, 'urlopen', return_value=feed(build)), self.assertRaises(RuntimeError):
                publisher.ensure_newer_release(latest, values)
        with self.assertRaises(RuntimeError):
            publisher.ensure_newer_release(dict(latest, tag_name='v0.1.9'), values)

    def test_local_fork_and_wrong_ref_cannot_start_publication(self):
        valid = {'GITHUB_REPOSITORY': 'YJBeetle/MacSW', 'GITHUB_REF': 'refs/heads/master',
                 'GITHUB_EVENT_NAME': 'workflow_dispatch'}
        with tempfile.TemporaryDirectory() as temporary:
            destination = Path(temporary) / 'output'
            for changes in [{'GITHUB_REPOSITORY': 'fork/MacSW'}, {'GITHUB_REF': 'refs/heads/feature'},
                            {'GITHUB_EVENT_NAME': 'pull_request'}]:
                with patch.dict(publisher.os.environ, dict(valid, **changes), clear=True), \
                        patch.object(publisher, 'api') as request, self.assertRaises(RuntimeError):
                    publisher.publish('12', destination)
                request.assert_not_called()
                self.assertFalse(destination.exists())

    def test_workflow_is_trusted_manual_or_post_signing_without_signing_secrets(self):
        text = (ROOT / '.github/workflows/publish-release.yml').read_text()
        self.assertIn('workflow_run:', text)
        self.assertIn('workflow_dispatch:', text)
        self.assertIn('branches: [master]', text)
        self.assertIn("github.event.workflow_run.conclusion == 'success'", text)
        self.assertIn('persist-credentials: false', text)
        self.assertIn('cancel-in-progress: false', text)
        self.assertNotIn('secrets.', text)
        self.assertNotIn('--clobber', text)
