"""Sign the final notarized ZIP and prepare a stable GitHub Release appcast.

Does not publish anything. A Release must upload the App and this feed together,
and may become latest only after all signing/bootstrap jobs have passed.
"""
import argparse
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

SPARKLE_URL = 'https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip'
SPARKLE_SHA256 = '17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959'
REPOSITORY = 'YJBeetle/MacSW'
NAMESPACE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NAMESPACE)

def q(name):
    return '{' + NAMESPACE + '}' + name

def create_feed(info, filename, length, signature):
    version = info['CFBundleShortVersionString']
    build = info['CFBundleVersion']
    if (not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or
            not re.fullmatch(r'[1-9][0-9]*', build) or
            filename != f'MacSW-{version}-macOS-signed.zip' or length <= 0 or
            len(base64.b64decode(signature, validate=True)) != 64):
        raise ValueError('Invalid stable update metadata')
    release = f'https://github.com/{REPOSITORY}/releases/tag/v{version}'
    rss = ET.Element('rss', version='2.0')
    channel = ET.SubElement(rss, 'channel')
    ET.SubElement(channel, 'title').text = 'MacSW'
    ET.SubElement(channel, 'link').text = f'https://github.com/{REPOSITORY}/releases'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = 'MacSW ' + version
    ET.SubElement(item, 'link').text = release
    # Plain text: no unsanitized Release HTML or third-party release notes.
    ET.SubElement(item, 'description').text = '更新说明：' + release
    ET.SubElement(item, q('version')).text = build
    ET.SubElement(item, q('shortVersionString')).text = version
    ET.SubElement(item, q('minimumSystemVersion')).text = info['LSMinimumSystemVersion']
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/{REPOSITORY}/releases/download/v{version}/{filename}',
        'length': str(length), 'type': 'application/octet-stream', q('edSignature'): signature})
    ET.indent(rss)
    return ET.tostring(rss, encoding='utf-8', xml_declaration=True)

def sign_update(archive, expected_public_key, secret):
    # Only accept the new seed format; do not silently read a CI login keychain.
    if len(base64.b64decode(secret, validate=True)) != 32:
        raise ValueError('Expected a 32-byte Sparkle private seed')
    derive = '''import Foundation
import CryptoKit
let input = FileHandle.standardInput.readDataToEndOfFile()
let seed = Data(base64Encoded: String(decoding: input, as: UTF8.self))!
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(key.publicKey.rawRepresentation.base64EncodedString())
'''
    with tempfile.TemporaryDirectory(prefix='macsw-update-sign-') as temporary:
        root = Path(temporary)
        helper = root / 'derive.swift'
        helper.write_text(derive)
        derived = subprocess.run(['swift', str(helper)], input=secret.encode(), capture_output=True, timeout=120)
        if derived.returncode or derived.stdout.decode().strip() != expected_public_key:
            raise RuntimeError('Update private key does not match the public key in the sealed App')
        # Fixed, checksum-pinned official tooling. Extract only this one binary.
        with urllib.request.urlopen(SPARKLE_URL, timeout=120) as response:
            payload = response.read(32 * 1024 * 1024)
        if hashlib.sha256(payload).hexdigest() != SPARKLE_SHA256:
            raise RuntimeError('Sparkle tool archive checksum mismatch')
        with zipfile.ZipFile(io.BytesIO(payload)) as bundle:
            tool = root / 'sign_update'
            tool.write_bytes(bundle.read('bin/sign_update'))
        tool.chmod(0o700)
        # Pass the key through stdin, never argv, logs or a persistent key file.
        result = subprocess.run([str(tool), '--ed-key-file', '-', '-p', str(archive)],
                                input=secret.encode(), capture_output=True, timeout=120)
        if result.returncode:
            raise RuntimeError('Update archive signing failed')
        return result.stdout.decode().strip()

def prepare(output):
    archives = list(output.glob('MacSW-*-macOS-signed.zip'))
    if len(archives) != 1:
        raise RuntimeError('Expected exactly one final signed archive')
    archive = archives[0]
    response = json.loads((output / 'notary-result.json').read_text())
    log = json.loads((output / 'notary-log.json').read_text())
    if (response.get('status') != 'Accepted' or log.get('status') != 'Accepted' or
            response.get('id') != log.get('jobId') or log.get('issues')):
        raise RuntimeError('Only an accepted notarized candidate can enter the update feed')
    with zipfile.ZipFile(archive) as bundle:
        info = plistlib.loads(bundle.read('MacSW.app/Contents/Info.plist'))
    secret = os.environ.get('SPARKLE_PRIVATE_KEY', '').strip()
    signature = sign_update(archive, info['SUPublicEDKey'], secret)
    (output / 'appcast.xml').write_bytes(create_feed(info, archive.name, archive.stat().st_size, signature))
    print('Stable update feed generated for the final notarized ZIP; not published.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    try:
        prepare(args.output)
    except Exception:
        # Tool diagnostics must never echo credential data on failure.
        raise SystemExit('Update feed generation failed; check key configuration, metadata and official tooling.') from None
