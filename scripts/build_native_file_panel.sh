#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/config.sh"
APP="$ROOT/build/native/MacSWFilePanel.app"
mkdir -p "$APP/Contents/MacOS"
/usr/bin/clang -fobjc-arc -Wall -Wextra -Werror -Wno-deprecated-declarations \
    -arch arm64 -arch x86_64 -mmacosx-version-min="$MACOS_DEPLOYMENT_TARGET" \
    "$ROOT/native/macsw_file_panel.m" -framework AppKit -o "$APP/Contents/MacOS/MacSWFilePanel"
/usr/bin/python3 - "$APP/Contents/Info.plist" "$MACOS_DEPLOYMENT_TARGET" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'wb') as stream:
    plistlib.dump({'CFBundleExecutable': 'MacSWFilePanel', 'CFBundleIdentifier': 'com.yjbeetle.macsw.file-panel',
                  'CFBundleName': 'MacSW', 'CFBundlePackageType': 'APPL', 'LSUIElement': True,
                  'LSMinimumSystemVersion': sys.argv[2], 'NSPrincipalClass': 'NSApplication'}, stream)
PY
/usr/bin/codesign --force --sign - "$APP"
