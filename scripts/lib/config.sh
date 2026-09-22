#!/usr/bin/env bash

if [ -n "${BASH_VERSION:-}" ]; then
    MACSW_CONFIG_SOURCE_PATH="${BASH_SOURCE[0]}"
elif [ -n "${ZSH_VERSION:-}" ]; then
    MACSW_CONFIG_SOURCE_PATH="${(%):-%x}"
else
    echo "scripts/lib/config.sh requires Bash or zsh" >&2
    return 1 2>/dev/null || exit 1
fi

MACSW_CONFIG_ROOT="$(cd "$(dirname "${MACSW_CONFIG_SOURCE_PATH}")/../.." && pwd)"
MACSW_VERSIONS_FILE="${MACSW_CONFIG_ROOT}/config/versions.env"

if [ ! -f "${MACSW_VERSIONS_FILE}" ]; then
    echo "Missing build version configuration: ${MACSW_VERSIONS_FILE}" >&2
    return 1 2>/dev/null || exit 1
fi

# shellcheck source=../../config/versions.env
source "${MACSW_VERSIONS_FILE}"

MACSW_REQUIRED_VERSION_KEYS=(
    APP_VERSION APP_BUILD MACOS_DEPLOYMENT_TARGET
    WINE_VERSION WINE_RUNTIME_SHA256 WINE_SOURCE_SHA256 WINE_DRIVER_DEPLOYMENT_TARGET
    WINE_MONO_VERSION MONO_PATCH_RELEASE MONO_PATCH_SOURCE_COMMIT MONO_PATCH_SHA256
    MONO_MSCORLIB_SHA256 MONO_REGASM_X86_SHA256 MONO_REGASM_X64_SHA256
    STDOLE_VERSION STDOLE_PACKAGE_SHA256 STDOLE_DLL_SHA256
    SEVEN_Z_VERSION SEVEN_Z_SHA256
    NOTO_SANS_SC_VERSION NOTO_SANS_SC_ARCHIVE_SHA256 NOTO_SANS_SC_REGULAR_SHA256
    NOTO_SANS_SC_BOLD_SHA256 NOTO_SANS_SC_LICENSE_SHA256
)

for MACSW_VERSION_KEY in "${MACSW_REQUIRED_VERSION_KEYS[@]}"; do
    eval "MACSW_VERSION_VALUE=\${${MACSW_VERSION_KEY}:-}"
    if [ -z "${MACSW_VERSION_VALUE}" ]; then
        echo "Missing required value in ${MACSW_VERSIONS_FILE}: ${MACSW_VERSION_KEY}" >&2
        return 1 2>/dev/null || exit 1
    fi
done
unset MACSW_VERSION_KEY MACSW_VERSION_VALUE MACSW_REQUIRED_VERSION_KEYS

WINE_SERIES="${WINE_VERSION%%.*}.x"
WINE_RUNTIME_ASSET="wine-devel-${WINE_VERSION}-osx64.tar.xz"
WINE_RUNTIME_URL="https://github.com/Gcenx/macOS_Wine_builds/releases/download/${WINE_VERSION}/${WINE_RUNTIME_ASSET}"
WINE_SOURCE_ASSET="wine-${WINE_VERSION}.tar.xz"
WINE_SOURCE_URL="https://dl.winehq.org/wine/source/${WINE_SERIES}/${WINE_SOURCE_ASSET}"
WINEMAC_OUTPUT_NAME="winemac-${WINE_VERSION}"
WINE_MONO_DIRECTORY="wine-mono-${WINE_MONO_VERSION}"
MONO_PATCH_URL="https://github.com/YJBeetle/wine-mono/releases/download/${MONO_PATCH_RELEASE}/libmono-2.0-x86.dll"
MONO_MSCORLIB_URL="https://github.com/YJBeetle/wine-mono/releases/download/${MONO_PATCH_RELEASE}/mscorlib.dll"
MONO_REGASM_X86_URL="https://github.com/YJBeetle/wine-mono/releases/download/${MONO_PATCH_RELEASE}/regasm-x86.exe"
MONO_REGASM_X64_URL="https://github.com/YJBeetle/wine-mono/releases/download/${MONO_PATCH_RELEASE}/regasm-x86_64.exe"
STDOLE_PACKAGE_ASSET="stdole.${STDOLE_VERSION}.nupkg"
STDOLE_PACKAGE_URL="https://api.nuget.org/v3-flatcontainer/stdole/${STDOLE_VERSION}/${STDOLE_PACKAGE_ASSET}"
STDOLE_OUTPUT_DIRECTORY="stdole-${STDOLE_VERSION}"
STDOLE_PACKAGE_MEMBER="lib/net10/stdole.dll"
SEVEN_Z_ASSET_VERSION="${SEVEN_Z_VERSION//./}"
SEVEN_Z_ARCHIVE_ASSET="7z${SEVEN_Z_ASSET_VERSION}-mac.tar.xz"
SEVEN_Z_URL="https://www.7-zip.org/a/${SEVEN_Z_ARCHIVE_ASSET}"
NOTO_SANS_SC_ARCHIVE_ASSET="NotoSansSC-${NOTO_SANS_SC_VERSION}.zip"
NOTO_SANS_SC_URL="https://github.com/notofonts/noto-cjk/releases/download/${NOTO_SANS_SC_VERSION}/18_NotoSansSC.zip"
NOTO_SANS_SC_OUTPUT_DIRECTORY="noto-sans-sc-${NOTO_SANS_SC_VERSION}"

unset MACSW_CONFIG_SOURCE_PATH
