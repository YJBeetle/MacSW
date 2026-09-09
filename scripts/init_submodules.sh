#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MacSW: Git Submodule 初始化与浅克隆脚本
# ==============================================================================

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBMODULE_PATH="${WORKSPACE_ROOT}/sources/wine-crossover"

echo "==> [MacSW] 正在初始化 Wine Submodule..."

cd "${WORKSPACE_ROOT}"

# 创建上层目录
mkdir -p "${WORKSPACE_ROOT}/sources"
mkdir -p "${WORKSPACE_ROOT}/patches/wine-crossover"

# 浅克隆以节省带宽与时间 (Wine 仓库完整历史大于 2GB)
if [ ! -d "${SUBMODULE_PATH}/.git" ] && [ ! -f "${SUBMODULE_PATH}/.git" ]; then
    echo "==> 正在执行浅克隆 (depth=1) sources/wine-crossover ..."
    git submodule update --init --recursive --depth 1 sources/wine-crossover || {
        echo "==> [WARN] 标准 submodule update 失败，尝试直接 git clone --depth 1 ..."
        git clone --depth 1 -b master https://github.com/Gcenx/wine.git "${SUBMODULE_PATH}"
    }
else
    echo "==> Submodule sources/wine-crossover 已经就绪。"
fi

echo "==> [SUCCESS] Submodule 初始化就绪！"
