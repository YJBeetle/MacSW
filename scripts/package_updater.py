"""Embed the pinned SwiftPM Sparkle framework; never invent update keys."""
import argparse
import base64
from pathlib import Path
import plistlib
import shutil

PROJECT = Path(__file__).resolve().parents[1]

def embed(app, framework, key_file, license_file):
    if framework.is_symlink() or not framework.is_dir() or framework.name != 'Sparkle.framework':
        raise RuntimeError('Expected the resolved official Sparkle.framework')
    destination = app / 'Contents/Frameworks/Sparkle.framework'
    if destination.exists():
        raise RuntimeError('Refusing to overwrite an existing embedded framework')
    shutil.copytree(framework, destination, symlinks=True)
    if not license_file.is_file():
        raise RuntimeError('Sparkle distribution license missing')
    licenses = app / 'Contents/Resources/licenses/Sparkle'
    licenses.mkdir(parents=True)
    shutil.copyfile(license_file, licenses / 'LICENSE')
    info_path = app / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    key = key_file.read_text().strip()
    if key:
        if len(base64.b64decode(key, validate=True)) != 32:
            raise RuntimeError('Sparkle EdDSA public key must contain 32 bytes')
        info['SUPublicEDKey'] = key
    else:
        # Local development may run without updater credentials. Distribution
        # signing will refuse this bundle until a reviewed public key is set.
        info.pop('SUPublicEDKey', None)
        print('Update public key not configured: development updater is disabled.')
    info_path.write_bytes(plistlib.dumps(info, sort_keys=False))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--framework', type=Path, required=True)
    parser.add_argument('--license', type=Path, required=True)
    args = parser.parse_args()
    embed(args.app, args.framework, PROJECT / 'config/sparkle-public-key.txt', args.license)
