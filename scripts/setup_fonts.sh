#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FONTS_DIR="${WORKSPACE_ROOT}/bottle/drive_c/windows/Fonts"

if [ -d "${FONTS_DIR}" ]; then
    cd "${FONTS_DIR}"
    if [ -f "msyh.ttc" ]; then
        echo "[INFO] 配置注册表 FontLink 机制支持微软雅黑回退（保留轻量原生 Tahoma 以确保秒开无卡顿）..."

        SW_DIR="${WORKSPACE_ROOT}/bottle/drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS"
        if [ -d "${SW_DIR}" ]; then
            if [ ! -f "${SW_DIR}/msyh.ttc" ] && [ -f "${FONTS_DIR}/msyh.ttc" ]; then
                cp -f "${FONTS_DIR}/msyh.ttc" "${SW_DIR}/msyh.ttc"
            fi
            ln -sf msyh.ttc "${SW_DIR}/segoeui.ttf"
        fi

        # 确保注册表 FontLink 与 FontSubstitutes 永久指向 Microsoft YaHei UI
        if [ -f "${WORKSPACE_ROOT}/scripts/diagnostics/fix_fontlink.exe" ]; then
            "${WINE:-wine}" "${WORKSPACE_ROOT}/scripts/diagnostics/fix_fontlink.exe" >/dev/null 2>&1 || true
        fi

        echo "[SUCCESS] 字体配置就绪！"
    fi
fi
