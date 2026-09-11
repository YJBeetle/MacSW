#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MacSW: Game Porting Toolkit (GPTK) 运行时环境拉取与准备脚本
# ==============================================================================

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${WORKSPACE_ROOT}/dist"
CACHE_DIR="${HOME}/Library/Caches/wine"
GPTK_VERSION="3.0-3"
GPTK_TAR="game-porting-toolkit-${GPTK_VERSION}.tar.xz"
GPTK_URL="https://github.com/Gcenx/game-porting-toolkit/releases/download/Game-Porting-Toolkit-${GPTK_VERSION}/${GPTK_TAR}"

mkdir -p "${DIST_DIR}" "${CACHE_DIR}"

echo "======================================================================"
echo "          MacSW: Game Porting Toolkit (GPTK) 独立运行时环境            "
echo "  版本: ${GPTK_VERSION} | 架构: WoW64 (32/64-bit) + D3DMetal            "
echo "======================================================================"

TARGET_FILE="${DIST_DIR}/${GPTK_TAR}"
if [ -f "${TARGET_FILE}" ]; then
    echo "==> [1/2] GPTK 运行时归档已存在: ${TARGET_FILE}"
elif [ -f "${CACHE_DIR}/${GPTK_TAR}" ]; then
    echo "==> [1/2] 从系统缓存同步 GPTK: ${CACHE_DIR}/${GPTK_TAR} -> ${TARGET_FILE}..."
    cp -p "${CACHE_DIR}/${GPTK_TAR}" "${TARGET_FILE}"
else
    echo "==> [1/2] 正在从 GitHub 官方 Releases 下载 Game Porting Toolkit (约 239MB)..."
    curl -fSL --progress-bar "${GPTK_URL}" -o "${TARGET_FILE}"
    cp -p "${TARGET_FILE}" "${CACHE_DIR}/${GPTK_TAR}" 2>/dev/null || true
fi

echo "==> [2/2] 正在验证 GPTK 运行时归档文件完整性..."
tar -tf "${TARGET_FILE}" | head -n 5 >/dev/null

echo "======================================================================"
echo "  [SUCCESS] Game Porting Toolkit 运行时环境就绪！"
echo "  路径: ${TARGET_FILE}"
echo "======================================================================"
