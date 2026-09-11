#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacSW"
mkdir -p "${WORKSPACE_ROOT}/build/app"
STAGING_ROOT="$(mktemp -d "${WORKSPACE_ROOT}/build/app/.package.XXXXXX")"
trap 'rm -rf "${STAGING_ROOT}"' EXIT
FINAL_APP_DIR="${WORKSPACE_ROOT}/build/app/${APP_NAME}.app"
APP_DIR="${STAGING_ROOT}/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MAC_OS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"
FRAMEWORKS_DIR="${CONTENTS_DIR}/Frameworks"

echo "======================================================================"
echo "          MacSW: 独立 macOS 应用程序打包工具                          "
echo "  目标: ${APP_NAME}.app                                               "
echo "======================================================================"

# 1. 编译原生 Bootstrap 引导程序
"${WORKSPACE_ROOT}/macos/Bootstrap/build_bootstrap.sh"

# 2. 创建 macOS App Bundle 规范目录
echo "==> 正在创建 App Bundle 结构..."
mkdir -p "${MAC_OS_DIR}"
mkdir -p "${RESOURCES_DIR}"
mkdir -p "${FRAMEWORKS_DIR}"

# 3. 复制 Mach-O 二进制与元数据及图标
echo "==> 正在装配二进制与 Info.plist..."
cp "${WORKSPACE_ROOT}/build/bootstrap/MacSW_Bootstrap" "${MAC_OS_DIR}/"
cp "${WORKSPACE_ROOT}/resources/Info.plist" "${CONTENTS_DIR}/"

# 如果尚未生成 App 图标，则自动从 Swift 源码渲染并编译
if [ ! -f "${WORKSPACE_ROOT}/macos/Resources/AppIcon.icns" ]; then
    echo "==> [MacSW] 检测到未预编译 AppIcon.icns，正在从源码光栅化渲染并构建图标..."
    "${WORKSPACE_ROOT}/scripts/generate_app_icon.swift"
fi

if [ -f "${WORKSPACE_ROOT}/macos/Resources/AppIcon.icns" ]; then
    cp "${WORKSPACE_ROOT}/macos/Resources/AppIcon.icns" "${RESOURCES_DIR}/"
fi

# Build and bundle the native helper for dialogs, fonts and floating windows.
"${WORKSPACE_ROOT}/scripts/build_ui_daemon.sh"
if [ -f "${WORKSPACE_ROOT}/scripts/sw_ui_daemon.exe" ]; then
    echo "==> 正在集成 sw_ui_daemon.exe..."
    cp -p "${WORKSPACE_ROOT}/scripts/sw_ui_daemon.exe" "${RESOURCES_DIR}/"
fi

# 集成 7-Zip 官方 Universal2 独立引擎 (确保无 Homebrew 的任意 Mac 均可极速解压)
SEVEN_Z_BIN="${WORKSPACE_ROOT}/dist/7zz"
if [ ! -f "${SEVEN_Z_BIN}" ]; then
    echo "==> 正在从 7-zip.org 获取官方 macOS Universal 2 独立版 7zz..."
    mkdir -p "${WORKSPACE_ROOT}/dist"
    curl -fSL "https://www.7-zip.org/a/7z2301-mac.tar.xz" | tar -xJf - -C "${WORKSPACE_ROOT}/dist" 7zz
    chmod +x "${SEVEN_Z_BIN}"
fi

if [ -f "${SEVEN_Z_BIN}" ]; then
    echo "==> 正在内置 7-Zip 官方 Universal2 引擎至 App Bundle..."
    cp -p "${SEVEN_Z_BIN}" "${MAC_OS_DIR}/7zz"
    ln -sf "7zz" "${MAC_OS_DIR}/7z"
fi

# 4. Pin the Gcenx build verified with the official installer.
WINE_VERSION="11.16"
WINE_ARCHIVE="${WORKSPACE_ROOT}/dist/wine-devel-${WINE_VERSION}-osx64.tar.xz"
WINE_SHA256="6f9af818b7af6001aeed7818cb32bf0155598c5ea4e3b33380a03cf814e033cd"
if [ ! -f "${WINE_ARCHIVE}" ]; then
    curl -fL --retry 3 "https://github.com/Gcenx/macOS_Wine_builds/releases/download/${WINE_VERSION}/wine-devel-${WINE_VERSION}-osx64.tar.xz" -o "${WINE_ARCHIVE}.download"
    mv "${WINE_ARCHIVE}.download" "${WINE_ARCHIVE}"
fi
ACTUAL_SHA256="$(shasum -a 256 "${WINE_ARCHIVE}" | awk '{print $1}')"
if [ "${ACTUAL_SHA256}" != "${WINE_SHA256}" ]; then
    echo "Wine archive SHA-256 mismatch; refusing to package." >&2
    exit 1
fi
WINE_UNPACK="${STAGING_ROOT}/runtime"
mkdir -p "${WINE_UNPACK}"
tar -xf "${WINE_ARCHIVE}" -C "${WINE_UNPACK}"
mv "${WINE_UNPACK}/Wine Devel.app/Contents/Resources/wine" "${FRAMEWORKS_DIR}/wine"
ln -sf wine "${FRAMEWORKS_DIR}/wine/bin/wineloader"
test -x "${FRAMEWORKS_DIR}/wine/bin/wineloader"
test -x "${FRAMEWORKS_DIR}/wine/bin/wineserver"
test -d "${FRAMEWORKS_DIR}/wine/share/wine/mono/wine-mono-11.3.0"

# Build and overlay the small native macOS driver patch. The complete Wine
# runtime still comes from the pinned Gcenx archive.
"${WORKSPACE_ROOT}/scripts/build_winemac.sh"
WINEMAC_PATCH="${WORKSPACE_ROOT}/dist/winemac-${WINE_VERSION}/winemac.so"
WINEMAC_TARGET="${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-unix/winemac.so"
cp "${WINEMAC_PATCH}" "${WINEMAC_TARGET}"
codesign --force --sign - "${WINEMAC_TARGET}"
codesign --verify --verbose=2 "${WINEMAC_TARGET}"

# GitHub CI run 34605603341; mono commit 50c8800d806195d7e55813d5cb59fd10b2fb4894.
MONO_PATCH="${WORKSPACE_ROOT}/dist/mono-11.3.0-v4/libmono-2.0-x86.dll"
if [ ! -f "${MONO_PATCH}" ]; then
    mkdir -p "$(dirname "${MONO_PATCH}")"
    curl -fL --retry 3 "https://github.com/YJBeetle/wine-mono/releases/download/macsw-mono-11.3.0-v4/libmono-2.0-x86.dll" -o "${MONO_PATCH}.download"
    test "$(shasum -a 256 "${MONO_PATCH}.download" | awk '{print $1}')" = "1541b5f189664e7f3d09d7e5ee5c3ae9e1c19534b79e8331fb9a51f9c1c21562" || { echo "Downloaded Mono DLL checksum mismatch" >&2; exit 1; }
    mv "${MONO_PATCH}.download" "${MONO_PATCH}"
fi
test "$(shasum -a 256 "${MONO_PATCH}" | awk '{print $1}')" = "1541b5f189664e7f3d09d7e5ee5c3ae9e1c19534b79e8331fb9a51f9c1c21562" || { echo "Mono DLL checksum mismatch" >&2; exit 1; }
cp "${MONO_PATCH}" "${FRAMEWORKS_DIR}/wine/share/wine/mono/wine-mono-11.3.0/bin/libmono-2.0-x86.dll"
test -f "${RESOURCES_DIR}/sw_ui_daemon.exe"
# Preserve matching mscoree and Mono; never inject the old CrossOver DLL.
"${FRAMEWORKS_DIR}/wine/bin/wineloader" --version
if [ -d "${FINAL_APP_DIR}" ]; then
    PREVIOUS_APP="${WORKSPACE_ROOT}/build/app/MacSW.previous.$(date +%Y%m%d-%H%M%S).app"
    mv "${FINAL_APP_DIR}" "${PREVIOUS_APP}"
    echo "Previous App retained at: ${PREVIOUS_APP}"
fi
mv "${APP_DIR}" "${FINAL_APP_DIR}"

echo "======================================================================"
echo "  [SUCCESS] 独立应用程序打包完成！"
echo "  路径: ${FINAL_APP_DIR}"
echo "======================================================================"
