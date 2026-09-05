#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CX_ROOT="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
export CX_BOTTLE="SolidWorks2025"
export PATH="${CX_ROOT}/bin:${PATH}"

WINE="${CX_ROOT}/bin/wine"
SW_DIR="${WORKSPACE_ROOT}/bottle/drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS"

echo "[INFO] 禁用 Wine GUI 崩溃阻断弹窗..."
"${WINE}" reg add 'HKLM\Software\Microsoft\Windows NT\CurrentVersion\AeDebug' /v Auto /t REG_SZ /d '0' /f >/dev/null 2>&1 || true

echo "[INFO] 验证 Visual C++ 核心库 (mfc140u, vcruntime140)..."
if [ -f "${WORKSPACE_ROOT}/bottle/drive_c/windows/system32/mfc140u.dll" ]; then
    echo "[SUCCESS] Visual C++ 运行库就绪"
else
    echo "[WARN] 未检测到 mfc140u.dll"
fi

echo "[INFO] 进入 SolidWorks 目录处理关键 COM/ActiveX 动态库..."
cd "${SW_DIR}"

for dll in sldshellutils.dll sldsearchcore.dll; do
    if [ -f "${dll}" ]; then
        echo "[INFO] 尝试注册: ${dll}"
        "${WINE}" regsvr32 /s "${dll}" >/dev/null 2>&1 || true
    fi
done

echo "[SUCCESS] COM 组件与基础依赖处理流程完成"
