#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/config.sh"
APP_DIR="${1:-${WORKSPACE_ROOT}/build/app/MacSW.app}"
CONTENTS_DIR="${APP_DIR}/Contents"
INFO_PLIST="${CONTENTS_DIR}/Info.plist"
RUNTIME_DIR="${CONTENTS_DIR}/Frameworks/wine"
MONO_DLL="${RUNTIME_DIR}/share/wine/mono/${WINE_MONO_DIRECTORY}/bin/libmono-2.0-x86.dll"
WINEMAC_DRIVER="${RUNTIME_DIR}/lib/wine/x86_64-unix/winemac.so"

test -d "${APP_DIR}"
plutil -lint "${INFO_PLIST}" >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")" = "${APP_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")" = "${APP_BUILD}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacSWWineVersion' "${INFO_PLIST}")" = "${WINE_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacSWMonoVersion' "${INFO_PLIST}")" = "${WINE_MONO_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${INFO_PLIST}")" = "${MACOS_DEPLOYMENT_TARGET}"

test -x "${CONTENTS_DIR}/MacOS/MacSW_Bootstrap"
test -x "${CONTENTS_DIR}/MacOS/7zz"
test -L "${CONTENTS_DIR}/MacOS/7z"
test -f "${CONTENTS_DIR}/Resources/AppIcon.icns"
test -f "${CONTENTS_DIR}/Resources/sw_ui_daemon.exe"
test -f "${CONTENTS_DIR}/Resources/BuildManifest.plist"
test -x "${RUNTIME_DIR}/bin/wineloader"
test -x "${RUNTIME_DIR}/bin/wineserver"
test "$(shasum -a 256 "${MONO_DLL}" | awk '{print $1}')" = "${MONO_PATCH_SHA256}"
file "${CONTENTS_DIR}/Resources/sw_ui_daemon.exe" | grep -q 'PE32+ executable.*x86-64'
file "${WINEMAC_DRIVER}" | grep -q 'Mach-O 64-bit dynamically linked shared library x86_64'
codesign --verify --verbose=2 "${WINEMAC_DRIVER}"

ACTUAL_WINE_VERSION="$("${RUNTIME_DIR}/bin/wineloader" --version)"
test "${ACTUAL_WINE_VERSION}" = "wine-${WINE_VERSION}" || {
    echo "Packaged Wine version mismatch: ${ACTUAL_WINE_VERSION}" >&2
    exit 1
}

echo "==> Verified ${APP_DIR}: MacSW ${APP_VERSION} (${APP_BUILD}), Wine ${WINE_VERSION}, Mono ${WINE_MONO_VERSION}"
