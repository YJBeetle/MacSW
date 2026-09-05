#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CX_ROOT="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
export CX_BOTTLE="SolidWorks2025"
export PATH="${CX_ROOT}/bin:${PATH}"
BOTTLE_REAL_PATH="${HOME}/Library/Application Support/CrossOver/Bottles/${CX_BOTTLE}"
BOTTLE_LINK="${WORKSPACE_ROOT}/bottle"

echo "[INFO] 检查/初始化 CrossOver Bottle: ${CX_BOTTLE}"

if [ ! -d "${BOTTLE_REAL_PATH}" ]; then
    echo "[INFO] 创建 64 位 Windows 10 Bottle (${CX_BOTTLE})..."
    "${CX_ROOT}/bin/cxbottle" --bottle "${CX_BOTTLE}" --create --template win10_64
fi

if [ -L "${BOTTLE_LINK}" ] && [ "$(readlink "${BOTTLE_LINK}")" = "${BOTTLE_REAL_PATH}" ]; then
    echo "[INFO] 工作区软链接正常: ${BOTTLE_LINK}"
else
    echo "[INFO] 创建/更新工作区软链接: ${BOTTLE_LINK} -> ${BOTTLE_REAL_PATH}"
    rm -rf "${BOTTLE_LINK}"
    ln -s "${BOTTLE_REAL_PATH}" "${BOTTLE_LINK}"
fi

echo "[INFO] 验证容器系统版本..."
"${CX_ROOT}/bin/wine" cmd.exe /c "ver"

echo "[SUCCESS] Wine 容器就绪: Windows 10 64-bit (${CX_BOTTLE})"
