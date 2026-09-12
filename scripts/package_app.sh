#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/config.sh"

APP_NAME="MacSW"
BUILD_ROOT="${WORKSPACE_ROOT}/build"
FINAL_APP_DIR="${BUILD_ROOT}/app/${APP_NAME}.app"
BOOTSTRAP_BIN="${BUILD_ROOT}/bootstrap/MacSW_Bootstrap"
UI_DAEMON_BIN="${BUILD_ROOT}/native/sw_ui_daemon.exe"
APP_ICON="${BUILD_ROOT}/resources/AppIcon.icns"
WINE_ARCHIVE="${WORKSPACE_ROOT}/dist/${WINE_RUNTIME_ASSET}"
WINEMAC_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/winemac.so"
MONO_PATCH="${WORKSPACE_ROOT}/dist/${MONO_PATCH_RELEASE}/libmono-2.0-x86.dll"
SEVEN_Z_BIN="${WORKSPACE_ROOT}/dist/7zz"

require_file() {
    if [ ! -f "$1" ]; then
        echo "Missing package input: $1" >&2
        exit 1
    fi
}

for PACKAGE_INPUT in "${BOOTSTRAP_BIN}" "${UI_DAEMON_BIN}" "${APP_ICON}" \
    "${WINE_ARCHIVE}" "${WINEMAC_PATCH}" "${MONO_PATCH}" "${SEVEN_Z_BIN}"; do
    require_file "${PACKAGE_INPUT}"
done
unset PACKAGE_INPUT

test "$(shasum -a 256 "${WINE_ARCHIVE}" | awk '{print $1}')" = "${WINE_RUNTIME_SHA256}" || { echo "Wine runtime checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${MONO_PATCH}" | awk '{print $1}')" = "${MONO_PATCH_SHA256}" || { echo "Mono patch checksum mismatch" >&2; exit 1; }

mkdir -p "${BUILD_ROOT}/app"
STAGING_ROOT="$(mktemp -d "${BUILD_ROOT}/app/.package.XXXXXX")"
trap 'rm -rf -- "${STAGING_ROOT}"' EXIT
APP_DIR="${STAGING_ROOT}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MAC_OS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"

echo "==> Assembling ${APP_NAME}.app..."
mkdir -p "${MAC_OS_DIR}" "${RESOURCES_DIR}" "${FRAMEWORKS_DIR}"
cp "${BOOTSTRAP_BIN}" "${MAC_OS_DIR}/MacSW_Bootstrap"
cp "${WORKSPACE_ROOT}/resources/Info.plist.in" "${CONTENTS_DIR}/Info.plist"
cp "${APP_ICON}" "${RESOURCES_DIR}/AppIcon.icns"
cp -p "${UI_DAEMON_BIN}" "${RESOURCES_DIR}/sw_ui_daemon.exe"
cp -p "${SEVEN_Z_BIN}" "${MAC_OS_DIR}/7zz"
ln -sf 7zz "${MAC_OS_DIR}/7z"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_BUILD}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWWineVersion ${WINE_VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWMonoVersion ${WINE_MONO_VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWMonoPatchSHA256 ${MONO_PATCH_SHA256}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion ${MACOS_DEPLOYMENT_TARGET}" "${CONTENTS_DIR}/Info.plist"

WINE_UNPACK="${STAGING_ROOT}/runtime"
mkdir -p "${WINE_UNPACK}"
tar -xf "${WINE_ARCHIVE}" -C "${WINE_UNPACK}"
mv "${WINE_UNPACK}/Wine Devel.app/Contents/Resources/wine" "${FRAMEWORKS_DIR}/wine"
ln -sf wine "${FRAMEWORKS_DIR}/wine/bin/wineloader"

WINEMAC_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-unix/winemac.so"
cp "${WINEMAC_PATCH}" "${WINEMAC_TARGET}"
codesign --force --sign - "${WINEMAC_TARGET}"
cp "${MONO_PATCH}" "${FRAMEWORKS_DIR}/wine/share/wine/mono/${WINE_MONO_DIRECTORY}/bin/libmono-2.0-x86.dll"

BUILD_MANIFEST="${RESOURCES_DIR}/BuildManifest.plist"
plutil -create xml1 "${BUILD_MANIFEST}"
PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0002-winemac-metal-layer-clipping.patch" | awk '{print $1}')"
/usr/libexec/PlistBuddy -c "Add :AppVersion string ${APP_VERSION}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :AppBuild string ${APP_BUILD}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineVersion string ${WINE_VERSION}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineRuntimeSHA256 string ${WINE_RUNTIME_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineSourceSHA256 string ${WINE_SOURCE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMacPatchSHA256 string ${PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoVersion string ${WINE_MONO_VERSION}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoPatchRelease string ${MONO_PATCH_RELEASE}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoPatchSourceCommit string ${MONO_PATCH_SOURCE_COMMIT}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoPatchSHA256 string ${MONO_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :SevenZipVersion string ${SEVEN_Z_VERSION}" "${BUILD_MANIFEST}"

if [ -d "${FINAL_APP_DIR}" ]; then
    rm -rf -- "${FINAL_APP_DIR}"
fi
mv "${APP_DIR}" "${FINAL_APP_DIR}"
echo "==> Packaged: ${FINAL_APP_DIR}"
