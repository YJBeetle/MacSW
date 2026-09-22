#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/config.sh"

APP_NAME="MacSW"
BUILD_ROOT="${WORKSPACE_ROOT}/build"
FINAL_APP_DIR="${MACSW_APP_OUTPUT:-${BUILD_ROOT}/app/${APP_NAME}.app}"
LAUNCHER_BIN="${BUILD_ROOT}/bootstrap/MacSW"
UI_DAEMON_BIN="${BUILD_ROOT}/native/sw_ui_daemon.exe"
APP_ICON="${BUILD_ROOT}/resources/AppIcon.icns"
WINE_ARCHIVE="${WORKSPACE_ROOT}/dist/${WINE_RUNTIME_ASSET}"
WINEMAC_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/winemac.so"
WIN32U_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/win32u.so"
WINE_LOADER_PATCH="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}/MacSW"
MONO_PATCH="${WORKSPACE_ROOT}/dist/${MONO_PATCH_RELEASE}/libmono-2.0-x86.dll"
MONO_MSCORLIB="${WORKSPACE_ROOT}/dist/${MONO_PATCH_RELEASE}/mscorlib.dll"
MONO_REGASM_X86="${WORKSPACE_ROOT}/dist/${MONO_PATCH_RELEASE}/regasm-x86.exe"
MONO_REGASM_X64="${WORKSPACE_ROOT}/dist/${MONO_PATCH_RELEASE}/regasm-x86_64.exe"
STDOLE_DLL="${WORKSPACE_ROOT}/dist/${STDOLE_OUTPUT_DIRECTORY}/stdole.dll"
SEVEN_Z_BIN="${WORKSPACE_ROOT}/dist/7zz"
SWCLI_ROOT="${WORKSPACE_ROOT}/Dependencies/SWCLI"
SWCLI_SOURCE="${SWCLI_ROOT}/src/swcli"
SWCLI_LICENSE="${SWCLI_ROOT}/LICENSE"
SWCLI_LAUNCHER="${WORKSPACE_ROOT}/scripts/swcli/sw-cli"
SWCLI_PATH_HELPER="${BUILD_ROOT}/native/swcli_path.exe"
SWCLI_PYTHON_ARCHIVE="${WORKSPACE_ROOT}/dist/${SWCLI_PYTHON_ARCHIVE_ASSET}"
SWCLI_PYWIN32_WHEEL="${WORKSPACE_ROOT}/dist/${SWCLI_PYWIN32_WHEEL_ASSET}"

require_file() {
    if [ ! -f "$1" ]; then
        echo "Missing package input: $1" >&2
        exit 1
    fi
}

for PACKAGE_INPUT in "${LAUNCHER_BIN}" "${UI_DAEMON_BIN}" "${APP_ICON}" \
    "${WINE_ARCHIVE}" "${WINEMAC_PATCH}" "${WIN32U_PATCH}" "${WINE_LOADER_PATCH}" "${MONO_PATCH}" "${MONO_MSCORLIB}" \
    "${MONO_REGASM_X86}" "${MONO_REGASM_X64}" "${STDOLE_DLL}" "${SEVEN_Z_BIN}" \
    "${SWCLI_SOURCE}/__init__.py" "${SWCLI_LICENSE}" "${SWCLI_LAUNCHER}" \
    "${SWCLI_PATH_HELPER}" "${SWCLI_PYTHON_ARCHIVE}" "${SWCLI_PYWIN32_WHEEL}"; do
    require_file "${PACKAGE_INPUT}"
done
unset PACKAGE_INPUT

test "$(shasum -a 256 "${WINE_ARCHIVE}" | awk '{print $1}')" = "${WINE_RUNTIME_SHA256}" || { echo "Wine runtime checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${MONO_PATCH}" | awk '{print $1}')" = "${MONO_PATCH_SHA256}" || { echo "Mono patch checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${MONO_MSCORLIB}" | awk '{print $1}')" = "${MONO_MSCORLIB_SHA256}" || { echo "Mono mscorlib checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${MONO_REGASM_X86}" | awk '{print $1}')" = "${MONO_REGASM_X86_SHA256}" || { echo "x86 RegAsm checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${MONO_REGASM_X64}" | awk '{print $1}')" = "${MONO_REGASM_X64_SHA256}" || { echo "x64 RegAsm checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${STDOLE_DLL}" | awk '{print $1}')" = "${STDOLE_DLL_SHA256}" || { echo "stdole DLL checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${SWCLI_PYTHON_ARCHIVE}" | awk '{print $1}')" = "${SWCLI_PYTHON_ARCHIVE_SHA256}" || { echo "Windows Python archive checksum mismatch" >&2; exit 1; }
test "$(shasum -a 256 "${SWCLI_PYWIN32_WHEEL}" | awk '{print $1}')" = "${SWCLI_PYWIN32_WHEEL_SHA256}" || { echo "pywin32 wheel checksum mismatch" >&2; exit 1; }
ACTUAL_SWCLI_COMMIT="$(git -C "${SWCLI_ROOT}" rev-parse HEAD)"
test "${ACTUAL_SWCLI_COMMIT}" = "${SWCLI_SOURCE_COMMIT}" || {
    echo "SWCLI submodule mismatch: expected ${SWCLI_SOURCE_COMMIT}, got ${ACTUAL_SWCLI_COMMIT}" >&2
    exit 1
}

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
cp "${LAUNCHER_BIN}" "${MAC_OS_DIR}/MacSW"
cp "${WORKSPACE_ROOT}/resources/Info.plist.in" "${CONTENTS_DIR}/Info.plist"
cp "${APP_ICON}" "${RESOURCES_DIR}/AppIcon.icns"
cp -p "${UI_DAEMON_BIN}" "${RESOURCES_DIR}/sw_ui_daemon.exe"
mkdir -p "${RESOURCES_DIR}/managed"
cp -p "${STDOLE_DLL}" "${RESOURCES_DIR}/managed/stdole.dll"
cp -p "${SEVEN_Z_BIN}" "${MAC_OS_DIR}/7zz"
ln -sf 7zz "${MAC_OS_DIR}/7z"
cp -p "${SWCLI_LAUNCHER}" "${MAC_OS_DIR}/sw-cli"
chmod +x "${MAC_OS_DIR}/sw-cli"
SWCLI_RUNTIME="${RESOURCES_DIR}/SWCLI/runtime/Python311"
SWCLI_SITE_PACKAGES="${SWCLI_RUNTIME}/Lib/site-packages"
mkdir -p "${RESOURCES_DIR}/SWCLI/bin" "${SWCLI_SITE_PACKAGES}" \
    "${RESOURCES_DIR}/SWCLI/licenses"
unzip -q "${SWCLI_PYTHON_ARCHIVE}" -d "${SWCLI_RUNTIME}"
unzip -q "${SWCLI_PYWIN32_WHEEL}" -d "${SWCLI_SITE_PACKAGES}"
tr -d '\r' < "${SWCLI_RUNTIME}/python311._pth" | awk '
    /^#import site$/ { print "Lib\\site-packages"; print "import site"; next }
    { print }
' > "${SWCLI_RUNTIME}/python311._pth.new"
mv "${SWCLI_RUNTIME}/python311._pth.new" "${SWCLI_RUNTIME}/python311._pth"
rsync -a --exclude='__pycache__' --exclude='*.pyc' \
    "${SWCLI_SOURCE}/" "${SWCLI_SITE_PACKAGES}/swcli/"
cp -p "${SWCLI_LICENSE}" "${RESOURCES_DIR}/SWCLI/licenses/SWCLI-LICENSE"
unzip -p "${SWCLI_PYTHON_ARCHIVE}" LICENSE.txt \
    > "${RESOURCES_DIR}/SWCLI/licenses/Python-LICENSE.txt"
unzip -p "${SWCLI_PYWIN32_WHEEL}" win32/License.txt \
    > "${RESOURCES_DIR}/SWCLI/licenses/pywin32-LICENSE.txt"
cp -p "${SWCLI_PATH_HELPER}" "${RESOURCES_DIR}/SWCLI/bin/swcli_path.exe"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${APP_VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${APP_BUILD}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWWineVersion ${WINE_VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWMonoVersion ${WINE_MONO_VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWMonoPatchSHA256 ${MONO_PATCH_SHA256}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWMonoMscorlibSHA256 ${MONO_MSCORLIB_SHA256}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWMonoRegAsmX86SHA256 ${MONO_REGASM_X86_SHA256}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWMonoRegAsmX64SHA256 ${MONO_REGASM_X64_SHA256}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWStdoleVersion ${STDOLE_VERSION}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :MacSWStdoleSHA256 ${STDOLE_DLL_SHA256}" "${CONTENTS_DIR}/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion ${MACOS_DEPLOYMENT_TARGET}" "${CONTENTS_DIR}/Info.plist"

WINE_UNPACK="${STAGING_ROOT}/runtime"
mkdir -p "${WINE_UNPACK}"
tar -xf "${WINE_ARCHIVE}" -C "${WINE_UNPACK}"
mv "${WINE_UNPACK}/Wine Devel.app/Contents/Resources/wine" "${FRAMEWORKS_DIR}/wine"
ln -sf wine "${FRAMEWORKS_DIR}/wine/bin/wineloader"

WINEMAC_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-unix/winemac.so"
WIN32U_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-unix/win32u.so"
NTDLL_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-unix/ntdll.so"
BRANDED_WINE_LOADER="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-unix/MacSW"
WINE_LOADER_COMPAT="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-unix/wine"
cp "${WINEMAC_PATCH}" "${WINEMAC_TARGET}"
cp "${WIN32U_PATCH}" "${WIN32U_TARGET}"
cp "${WINE_LOADER_PATCH}" "${BRANDED_WINE_LOADER}"
ln -sf MacSW "${WINE_LOADER_COMPAT}"
codesign --force --sign - "${WINEMAC_TARGET}"
codesign --force --sign - "${WIN32U_TARGET}"
codesign --force --sign - "${BRANDED_WINE_LOADER}"
cp "${MONO_PATCH}" "${FRAMEWORKS_DIR}/wine/share/wine/mono/${WINE_MONO_DIRECTORY}/bin/libmono-2.0-x86.dll"
cp "${MONO_MSCORLIB}" "${FRAMEWORKS_DIR}/wine/share/wine/mono/${WINE_MONO_DIRECTORY}/lib/mono/4.5/mscorlib.dll"
cp "${MONO_REGASM_X86}" "${FRAMEWORKS_DIR}/wine/lib/wine/i386-windows/regasm.exe"
cp "${MONO_REGASM_X64}" "${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-windows/regasm.exe"

BUILD_MANIFEST="${RESOURCES_DIR}/BuildManifest.plist"
plutil -create xml1 "${BUILD_MANIFEST}"
WINEMAC_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0002-winemac-metal-layer-clipping.patch" | awk '{print $1}')"
WIN32U_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0003-win32u-no-capture-resend.patch" | awk '{print $1}')"
WINEMAC_OPENGL_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0004-winemac-preserve-front-buffer-flush.patch" | awk '{print $1}')"
WINEMAC_BRANDING_PATCH_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0005-winemac-macsw-branding.patch" | awk '{print $1}')"
WINEMAC_MODULE_SHA256="$(shasum -a 256 "${WINEMAC_TARGET}" | awk '{print $1}')"
WIN32U_MODULE_SHA256="$(shasum -a 256 "${WIN32U_TARGET}" | awk '{print $1}')"
NTDLL_MODULE_SHA256="$(shasum -a 256 "${NTDLL_TARGET}" | awk '{print $1}')"
WINE_LOADER_SHA256="$(shasum -a 256 "${BRANDED_WINE_LOADER}" | awk '{print $1}')"
/usr/libexec/PlistBuddy -c "Add :AppVersion string ${APP_VERSION}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :AppBuild string ${APP_BUILD}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineVersion string ${WINE_VERSION}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineRuntimeSHA256 string ${WINE_RUNTIME_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineSourceSHA256 string ${WINE_SOURCE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMacPatchSHA256 string ${WINEMAC_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineInputPatchSHA256 string ${WIN32U_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMacOpenGLPatchSHA256 string ${WINEMAC_OPENGL_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMacBrandingPatchSHA256 string ${WINEMAC_BRANDING_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineMacModuleSHA256 string ${WINEMAC_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineInputModuleSHA256 string ${WIN32U_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineNtdllModuleSHA256 string ${NTDLL_MODULE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :WineLoaderSHA256 string ${WINE_LOADER_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoVersion string ${WINE_MONO_VERSION}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoPatchRelease string ${MONO_PATCH_RELEASE}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoPatchSourceCommit string ${MONO_PATCH_SOURCE_COMMIT}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoPatchSHA256 string ${MONO_PATCH_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoMscorlibSHA256 string ${MONO_MSCORLIB_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoRegAsmX86SHA256 string ${MONO_REGASM_X86_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :MonoRegAsmX64SHA256 string ${MONO_REGASM_X64_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :StdoleVersion string ${STDOLE_VERSION}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :StdolePackageSHA256 string ${STDOLE_PACKAGE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :StdoleDLLSHA256 string ${STDOLE_DLL_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :SevenZipVersion string ${SEVEN_Z_VERSION}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :SWCLIVersion string ${SWCLI_VERSION}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :SWCLISourceCommit string ${SWCLI_SOURCE_COMMIT}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :SWCLIPythonVersion string ${SWCLI_PYTHON_VERSION}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :SWCLIPythonArchiveSHA256 string ${SWCLI_PYTHON_ARCHIVE_SHA256}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :SWCLIPyWin32Version string ${SWCLI_PYWIN32_VERSION}" "${BUILD_MANIFEST}"
/usr/libexec/PlistBuddy -c "Add :SWCLIPyWin32WheelSHA256 string ${SWCLI_PYWIN32_WHEEL_SHA256}" "${BUILD_MANIFEST}"

mkdir -p "$(dirname "${FINAL_APP_DIR}")"
if [ -d "${FINAL_APP_DIR}" ]; then
    rm -rf -- "${FINAL_APP_DIR}"
fi
mv "${APP_DIR}" "${FINAL_APP_DIR}"
echo "==> Packaged: ${FINAL_APP_DIR}"
