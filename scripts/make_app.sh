#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SolidWorks 2025"
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

# 3. 复制 Mach-O 二进制与元数据
echo "==> 正在装配二进制与 Info.plist..."
cp "${WORKSPACE_ROOT}/build/bootstrap/MacSW_Bootstrap" "${MAC_OS_DIR}/"
cp "${WORKSPACE_ROOT}/resources/Info.plist" "${CONTENTS_DIR}/"

# 4. 集成定制版 Wine Runtime (如果本地有编译产物)
WINE_TAR="${WORKSPACE_ROOT}/dist/wine-crossover-macsw-arm64.tar.gz"
if [ -f "${WINE_TAR}" ]; then
    echo "==> 正在解压并内置 Wine Runtime: ${WINE_TAR}..."
    mkdir -p "${FRAMEWORKS_DIR}/wine"
    tar -xzf "${WINE_TAR}" -C "${FRAMEWORKS_DIR}/wine"
else
    echo "==> [NOTICE] 未在 dist/ 发现编译好的 wine tar.gz，App 将在运行时智能检测系统环境或等待 CI 产物注入。"
fi

echo "======================================================================"
echo "  [SUCCESS] 独立应用程序打包完成！"
echo "  路径: ${APP_DIR}"
echo "======================================================================"
