#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FONTS_DIR="${WORKSPACE_ROOT}/bottle/drive_c/windows/Fonts"

if [ -d "${FONTS_DIR}" ]; then
    cd "${FONTS_DIR}"
    if [ -f "msyh.ttc" ]; then
        echo "[INFO] 配置 Segoe UI 与 Tahoma 字体链接至 Microsoft YaHei..."
        ln -sf msyh.ttc segoeui.ttf
        ln -sf msyhbd.ttc segoeuib.ttf
        ln -sf msyhl.ttc segoeuil.ttf
        ln -sf msyh.ttc segoeuii.ttf
        ln -sf msyh.ttc segoeuisl.ttf
        ln -sf msyh.ttc segoeuiz.ttf
        ln -sf msyh.ttc tahoma.ttf
        ln -sf msyhbd.ttc tahomabd.ttf
        ln -sf msyh.ttc Tahoma.ttf
        ln -sf msyhbd.ttc "Tahoma Bold.ttf"
        echo "[SUCCESS] 字体配置就绪！"
    fi
fi
