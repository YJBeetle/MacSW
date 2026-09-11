#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="MacSW"
APP_DIR="${WORKSPACE_ROOT}/build/app/${APP_NAME}.app"
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
rm -rf "${APP_DIR}"
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

# 集成 SolidWorks UI 守护进程 (自动修复 3D 视口 Metal 与特征树 GDI 渲染遮挡闪避)
if [ -f "${WORKSPACE_ROOT}/scripts/sw_ui_daemon.exe" ]; then
    echo "==> 正在集成 sw_ui_daemon.exe..."
    cp -p "${WORKSPACE_ROOT}/scripts/sw_ui_daemon.exe" "${RESOURCES_DIR}/"
fi

# 4. 集成独立 Wine Runtime (优先使用 Game Porting Toolkit 官方二进制发布)
GPTK_VERSION="3.0-3"
GPTK_TAR="game-porting-toolkit-${GPTK_VERSION}.tar.xz"
GPTK_PATH="${WORKSPACE_ROOT}/dist/${GPTK_TAR}"
GPTK_SYS_CACHE="${HOME}/Library/Caches/wine/${GPTK_TAR}"

if [ ! -f "${GPTK_PATH}" ] && [ -f "${GPTK_SYS_CACHE}" ]; then
    echo "==> 从系统缓存同步 GPTK: ${GPTK_SYS_CACHE} -> ${GPTK_PATH}..."
    cp -p "${GPTK_SYS_CACHE}" "${GPTK_PATH}"
fi

if [ ! -f "${GPTK_PATH}" ]; then
    echo "==> 正在从 GitHub 官方 Releases 下载 Game Porting Toolkit (约 239MB)..."
    mkdir -p "${WORKSPACE_ROOT}/dist"
    curl -fSL --progress-bar "https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-${GPTK_VERSION}/${GPTK_TAR}" -o "${GPTK_PATH}"
    cp -p "${GPTK_PATH}" "${GPTK_SYS_CACHE}" 2>/dev/null || true
fi

if [ -f "${GPTK_PATH}" ]; then
    echo "==> 正在解压并内置 Game Porting Toolkit Wine Runtime..."
    mkdir -p "${FRAMEWORKS_DIR}"
    rm -rf "${FRAMEWORKS_DIR}/wine" "${FRAMEWORKS_DIR}/Game Porting Toolkit.app"
    tar -xf "${GPTK_PATH}" -C "${FRAMEWORKS_DIR}"
    if [ -d "${FRAMEWORKS_DIR}/Game Porting Toolkit.app/Contents/Resources/wine" ]; then
        mv "${FRAMEWORKS_DIR}/Game Porting Toolkit.app/Contents/Resources/wine" "${FRAMEWORKS_DIR}/wine"
        rm -rf "${FRAMEWORKS_DIR}/Game Porting Toolkit.app"
    fi

    # 确保 wine 与 wineloader 符号链接存在 (指向 wine64)
    if [ -f "${FRAMEWORKS_DIR}/wine/bin/wine64" ]; then
        ln -sf wine64 "${FRAMEWORKS_DIR}/wine/bin/wine"
        ln -sf wine64 "${FRAMEWORKS_DIR}/wine/bin/wineloader"
    fi

    # 5. 确保内置修复版 mscoree.dll 与 wine-mono-10.4.1 就位 (解决 C++/CLI 虚表修复断言崩溃)
    MSCOREE_CANDIDATE="${WORKSPACE_ROOT}/dist/mscoree_x64.dll"
    if [ -f "${MSCOREE_CANDIDATE}" ]; then
        echo "==> 正在集成修复版 mscoree.dll (支持 C++/CLI 虚表修复)..."
        mkdir -p "${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-windows"
        cp -p "${MSCOREE_CANDIDATE}" "${FRAMEWORKS_DIR}/wine/lib/wine/x86_64-windows/mscoree.dll"
    fi

    # wine-mono-10.4.1 官方标准包优雅获取与集成（纯独立，不依赖外部商业软件）
    MONO_TARGET_DIR="${FRAMEWORKS_DIR}/wine/share/wine/mono/wine-mono-10.4.1"
    if [ ! -d "${MONO_TARGET_DIR}" ]; then
        echo "==> 正在准备 wine-mono-10.4.1 运行时..."
        mkdir -p "${FRAMEWORKS_DIR}/wine/share/wine/mono"
        
        MONO_CACHE_TAR="${WORKSPACE_ROOT}/dist/wine-mono-10.4.1-x86.tar.xz"
        MONO_SYS_CACHE="${HOME}/Library/Caches/wine/wine-mono-10.4.1-x86.tar.xz"
        
        if [ -f "${MONO_CACHE_TAR}" ]; then
            echo "==> 使用 dist/ 缓存的 wine-mono-10.4.1-x86.tar.xz..."
            tar -xf "${MONO_CACHE_TAR}" -C "${FRAMEWORKS_DIR}/wine/share/wine/mono/"
        elif [ -f "${MONO_SYS_CACHE}" ]; then
            echo "==> 使用系统级缓存的 wine-mono-10.4.1-x86.tar.xz..."
            tar -xf "${MONO_SYS_CACHE}" -C "${FRAMEWORKS_DIR}/wine/share/wine/mono/"
        else
            echo "==> 正在从 WineHQ 官方下载标准 wine-mono-10.4.1-x86.tar.xz (约 38MB)..."
            mkdir -p "${WORKSPACE_ROOT}/dist"
            curl -fSL --progress-bar "https://dl.winehq.org/wine/wine-mono/10.4.1/wine-mono-10.4.1-x86.tar.xz" -o "${MONO_CACHE_TAR}"
            tar -xf "${MONO_CACHE_TAR}" -C "${FRAMEWORKS_DIR}/wine/share/wine/mono/"
        fi
    fi
else
    echo "==> [NOTICE] 未在 dist/ 发现 wine 运行时包，App 将在运行时智能检测系统环境。"
fi

echo "======================================================================"
echo "  [SUCCESS] 独立应用程序打包完成！"
echo "  路径: ${APP_DIR}"
echo "======================================================================"
