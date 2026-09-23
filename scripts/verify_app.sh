#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/config.sh"
APP_DIR="${1:-${WORKSPACE_ROOT}/build/app/MacSW.app}"
CONTENTS_DIR="${APP_DIR}/Contents"
INFO_PLIST="${CONTENTS_DIR}/Info.plist"
RUNTIME_DIR="${CONTENTS_DIR}/Frameworks/wine"
MONO_DLL="${RUNTIME_DIR}/share/wine/mono/${WINE_MONO_DIRECTORY}/bin/libmono-2.0-x86.dll"
MONO_MSCORLIB="${RUNTIME_DIR}/share/wine/mono/${WINE_MONO_DIRECTORY}/lib/mono/4.5/mscorlib.dll"
MONO_REGASM_X86="${RUNTIME_DIR}/lib/wine/i386-windows/regasm.exe"
MONO_REGASM_X64="${RUNTIME_DIR}/lib/wine/x86_64-windows/regasm.exe"
WINEMAC_DRIVER="${RUNTIME_DIR}/lib/wine/x86_64-unix/winemac.so"
WIN32U_DRIVER="${RUNTIME_DIR}/lib/wine/x86_64-unix/win32u.so"
STDOLE_DLL="${CONTENTS_DIR}/Resources/managed/stdole.dll"
BUILD_MANIFEST="${CONTENTS_DIR}/Resources/BuildManifest.plist"
SWCLI_DIR="${CONTENTS_DIR}/Resources/SWCLI"
SWCLI_LAUNCHER="${CONTENTS_DIR}/MacOS/sw-cli"
SWCLI_PATH_HELPER="${SWCLI_DIR}/bin/swcli_path.exe"
SWCLI_RUNTIME="${SWCLI_DIR}/runtime/Python311"

test -d "${APP_DIR}"
plutil -lint "${INFO_PLIST}" >/dev/null
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")" = "${APP_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")" = "${APP_BUILD}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacSWWineVersion' "${INFO_PLIST}")" = "${WINE_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacSWMonoVersion' "${INFO_PLIST}")" = "${WINE_MONO_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacSWMonoMscorlibSHA256' "${INFO_PLIST}")" = "${MONO_MSCORLIB_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacSWMonoRegAsmX86SHA256' "${INFO_PLIST}")" = "${MONO_REGASM_X86_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacSWMonoRegAsmX64SHA256' "${INFO_PLIST}")" = "${MONO_REGASM_X64_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacSWStdoleVersion' "${INFO_PLIST}")" = "${STDOLE_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MacSWStdoleSHA256' "${INFO_PLIST}")" = "${STDOLE_DLL_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "${INFO_PLIST}")" = "${MACOS_DEPLOYMENT_TARGET}"

test -x "${CONTENTS_DIR}/MacOS/MacSW"
test -x "${CONTENTS_DIR}/MacOS/7zz"
test -x "${SWCLI_LAUNCHER}"
test -L "${CONTENTS_DIR}/MacOS/7z"
test -f "${CONTENTS_DIR}/Resources/AppIcon.icns"
test -f "${CONTENTS_DIR}/Resources/sw_ui_daemon.exe"
test -f "${BUILD_MANIFEST}"
test -f "${SWCLI_RUNTIME}/python.exe"
test -f "${SWCLI_RUNTIME}/Lib/site-packages/pywin32_system32/pythoncom311.dll"
test -f "${SWCLI_RUNTIME}/Lib/site-packages/win32com/client/__init__.py"
test -f "${SWCLI_RUNTIME}/Lib/site-packages/swcli/__main__.py"
test -f "${SWCLI_RUNTIME}/Lib/site-packages/swcli/schemas/v1/request.schema.json"
grep -Fxq 'Lib\site-packages' "${SWCLI_RUNTIME}/python311._pth"
grep -Fxq 'import site' "${SWCLI_RUNTIME}/python311._pth"
test -f "${SWCLI_DIR}/licenses/SWCLI-LICENSE"
test -s "${SWCLI_DIR}/licenses/Python-LICENSE.txt"
test -s "${SWCLI_DIR}/licenses/pywin32-LICENSE.txt"
test -z "$(find "${SWCLI_RUNTIME}" -type d -name __pycache__ -print -quit)"
test -z "$(find "${SWCLI_RUNTIME}" -type f -name '*.pyc' -print -quit)"
test -f "${SWCLI_PATH_HELPER}"
test "$(shasum -a 256 "${STDOLE_DLL}" | awk '{print $1}')" = "${STDOLE_DLL_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMacPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0002-winemac-metal-layer-clipping.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineInputPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0003-win32u-no-capture-resend.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMacOpenGLPatchSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WORKSPACE_ROOT}/patches/wine-crossover/0004-winemac-preserve-front-buffer-flush.patch" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineMacModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WINEMAC_DRIVER}" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :WineInputModuleSHA256' "${BUILD_MANIFEST}")" = "$(shasum -a 256 "${WIN32U_DRIVER}" | awk '{print $1}')"
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoPatchRelease' "${BUILD_MANIFEST}")" = "${MONO_PATCH_RELEASE}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoPatchSourceCommit' "${BUILD_MANIFEST}")" = "${MONO_PATCH_SOURCE_COMMIT}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoPatchSHA256' "${BUILD_MANIFEST}")" = "${MONO_PATCH_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoMscorlibSHA256' "${BUILD_MANIFEST}")" = "${MONO_MSCORLIB_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoRegAsmX86SHA256' "${BUILD_MANIFEST}")" = "${MONO_REGASM_X86_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :MonoRegAsmX64SHA256' "${BUILD_MANIFEST}")" = "${MONO_REGASM_X64_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :StdoleVersion' "${BUILD_MANIFEST}")" = "${STDOLE_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :StdolePackageSHA256' "${BUILD_MANIFEST}")" = "${STDOLE_PACKAGE_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :StdoleDLLSHA256' "${BUILD_MANIFEST}")" = "${STDOLE_DLL_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :SWCLIVersion' "${BUILD_MANIFEST}")" = "${SWCLI_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :SWCLISourceCommit' "${BUILD_MANIFEST}")" = "${SWCLI_SOURCE_COMMIT}"
test "$(/usr/libexec/PlistBuddy -c 'Print :SWCLIPythonVersion' "${BUILD_MANIFEST}")" = "${SWCLI_PYTHON_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :SWCLIPythonArchiveSHA256' "${BUILD_MANIFEST}")" = "${SWCLI_PYTHON_ARCHIVE_SHA256}"
test "$(/usr/libexec/PlistBuddy -c 'Print :SWCLIPyWin32Version' "${BUILD_MANIFEST}")" = "${SWCLI_PYWIN32_VERSION}"
test "$(/usr/libexec/PlistBuddy -c 'Print :SWCLIPyWin32WheelSHA256' "${BUILD_MANIFEST}")" = "${SWCLI_PYWIN32_WHEEL_SHA256}"
test -x "${RUNTIME_DIR}/bin/wineloader"
test -x "${RUNTIME_DIR}/bin/wineserver"
test "$(shasum -a 256 "${MONO_DLL}" | awk '{print $1}')" = "${MONO_PATCH_SHA256}"
test "$(shasum -a 256 "${MONO_MSCORLIB}" | awk '{print $1}')" = "${MONO_MSCORLIB_SHA256}"
test "$(shasum -a 256 "${MONO_REGASM_X86}" | awk '{print $1}')" = "${MONO_REGASM_X86_SHA256}"
test "$(shasum -a 256 "${MONO_REGASM_X64}" | awk '{print $1}')" = "${MONO_REGASM_X64_SHA256}"
file "${MONO_REGASM_X86}" | grep -q 'PE32 executable.*Intel 80386 Mono/.Net assembly'
file "${MONO_REGASM_X64}" | grep -q 'PE32+ executable.*x86-64 Mono/.Net assembly'
file "${CONTENTS_DIR}/Resources/sw_ui_daemon.exe" | grep -q 'PE32+ executable.*x86-64'
file "${SWCLI_PATH_HELPER}" | grep -q 'PE32+ executable.*x86-64'
file "${SWCLI_RUNTIME}/python.exe" | grep -q 'PE32+ executable.*x86-64'
file "${WINEMAC_DRIVER}" | grep -q 'Mach-O 64-bit dynamically linked shared library x86_64'
file "${WIN32U_DRIVER}" | grep -q 'Mach-O 64-bit dynamically linked shared library x86_64'
otool -l "${WIN32U_DRIVER}" | grep -A2 LC_RPATH | grep -q '@loader_path/../../'
codesign --verify --verbose=2 "${WINEMAC_DRIVER}"
codesign --verify --verbose=2 "${WIN32U_DRIVER}"

ACTUAL_WINE_VERSION="$("${RUNTIME_DIR}/bin/wineloader" --version)"
test "${ACTUAL_WINE_VERSION}" = "wine-${WINE_VERSION}" || {
    echo "Packaged Wine version mismatch: ${ACTUAL_WINE_VERSION}" >&2
    exit 1
}

echo "==> Verified ${APP_DIR}: MacSW ${APP_VERSION} (${APP_BUILD}), Wine ${WINE_VERSION}, Mono ${WINE_MONO_VERSION}, SWCLI ${SWCLI_VERSION}"
