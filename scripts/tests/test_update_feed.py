"""No production update keys; validate feed and packaging contracts offline."""
import base64
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import zipfile

PROJECT = Path(__file__).resolve().parents[2]

def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, PROJECT / relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

feed = load('update_feed', 'scripts/ci/update-feed.py')
package = load('package_updater', 'scripts/package_updater.py')

class UpdateFeedTests(unittest.TestCase):
    info = {'CFBundleShortVersionString': '0.1.3', 'CFBundleVersion': '5', 'LSMinimumSystemVersion': '13.0'}
    signature = base64.b64encode(bytes(64)).decode()

    def test_feed_uses_immutable_release_url_and_monotonic_build(self):
        root = ET.fromstring(feed.create_feed(self.info, 'MacSW-0.1.3-macOS-signed.zip', 1234, self.signature))
        item = root.find('channel/item')
        self.assertEqual(item.find(feed.q('version')).text, '5')
        self.assertEqual(item.find(feed.q('shortVersionString')).text, '0.1.3')
        self.assertEqual(item.find(feed.q('minimumSystemVersion')).text, '13.0')
        enclosure = item.find('enclosure')
        self.assertEqual(enclosure.get('url'), 'https://github.com/YJBeetle/MacSW/releases/download/v0.1.3/MacSW-0.1.3-macOS-signed.zip')
        self.assertEqual(enclosure.get(feed.q('edSignature')), self.signature)
        self.assertEqual(enclosure.get('length'), '1234')

    def test_prerelease_and_unsafe_metadata_never_enter_stable_feed(self):
        for changes in [{'CFBundleShortVersionString': '0.1.3-beta'}, {'CFBundleVersion': '0'},
                        {'CFBundleVersion': '5\nmalformed'}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                feed.create_feed(dict(self.info, **changes), 'MacSW-0.1.3-macOS-signed.zip', 1, self.signature)
        for name, length, signature in [('other.zip', 1, self.signature), ('MacSW-0.1.3-macOS-signed.zip', 0, self.signature),
                                       ('MacSW-0.1.3-macOS-signed.zip', 1, 'invalid')]:
            with self.assertRaises(ValueError):
                feed.create_feed(self.info, name, length, signature)

    def test_private_key_mismatch_fails_before_download_or_signing(self):
        from types import SimpleNamespace
        seed = base64.b64encode(bytes(32)).decode()
        with patch.object(feed.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=b'other-key')), \
                patch.object(feed.urllib.request, 'urlopen') as download:
            with self.assertRaisesRegex(RuntimeError, 'does not match'):
                feed.sign_update(Path('/not-used.zip'), 'expected-key', seed)
            download.assert_not_called()

    def test_unsigned_or_rejected_candidate_cannot_generate_feed(self):
        import json
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'MacSW-0.1.3-macOS-signed.zip').write_bytes(b'not-read')
            for name in ['notary-result.json', 'notary-log.json']:
                (root / name).write_text(json.dumps({'status': 'Invalid'}))
            with patch.object(feed, 'sign_update') as sign:
                with self.assertRaisesRegex(RuntimeError, 'accepted notarized'):
                    feed.prepare(root)
                sign.assert_not_called()

    def test_packaging_preserves_framework_links_and_embeds_only_public_key(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            framework = root / 'Sparkle.framework'
            version = framework / 'Versions/B'
            version.mkdir(parents=True)
            (version / 'Sparkle').write_bytes(b'fixture')
            (framework / 'Versions/Current').symlink_to('B')
            (framework / 'Sparkle').symlink_to('Versions/Current/Sparkle')
            app = root / 'MacSW.app'
            (app / 'Contents/Frameworks').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({}))
            public_key = root / 'public-key'
            key = base64.b64encode(bytes(32)).decode()
            public_key.write_text(key)
            license_file = root / 'LICENSE'
            license_file.write_text('Sparkle license')
            package.embed(app, framework, public_key, license_file)
            self.assertEqual(plistlib.loads((app / 'Contents/Info.plist').read_bytes())['SUPublicEDKey'], key)
            self.assertTrue((app / 'Contents/Frameworks/Sparkle.framework/Sparkle').is_symlink())
            self.assertEqual((app / 'Contents/Resources/licenses/Sparkle/LICENSE').read_text(), 'Sparkle license')

    def test_ci_generates_feed_after_notarization_and_keeps_credentials_step_scoped(self):
        workflow = (PROJECT / '.github/workflows/sign-app.yml').read_text()
        self.assertLess(workflow.index('python3 -B scripts/ci/notarize-app.py'), workflow.index('python3 -B scripts/ci/update-feed.py'))
        self.assertIn('SPARKLE_PRIVATE_KEY: ${{ secrets.SPARKLE_PRIVATE_KEY }}', workflow)
        self.assertIn('${{ runner.temp }}/macsw-distribution/appcast.xml', workflow)
        plist = plistlib.loads((PROJECT / 'resources/Info.plist.in').read_bytes())
        self.assertFalse(plist['SUAllowsAutomaticUpdates'])
        self.assertFalse(plist['SUAutomaticallyUpdate'])
        self.assertFalse(plist['SUSendProfileInfo'])
        self.assertEqual(plist['SUFeedURL'], 'https://github.com/YJBeetle/MacSW/releases/latest/download/appcast.xml')
