#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CX_ROOT="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
export CX_BOTTLE="SolidWorks2025"
export PATH="${CX_ROOT}/bin:${PATH}"

WINE="${CX_ROOT}/bin/wine"

echo "[INFO] 导入 SolidWorks 机器注册表 (SWHKLM.reg)..."
"${WINE}" reg import "${WORKSPACE_ROOT}/C/SWHKLM.reg"

echo "[INFO] 导入 SolidWorks 用户注册表 (SWHKCU.reg)..."
"${WINE}" reg import "${WORKSPACE_ROOT}/C/SWHKCU.reg"

echo "[INFO] 注入 FlexNet 许可服务器配置 (25734@localhost)..."
"${WINE}" reg add 'HKLM\SOFTWARE\FLEXlm License Manager' /v SW_D_LICENSE_FILE /t REG_SZ /d '25734@localhost' /f
"${WINE}" reg add 'HKCU\SOFTWARE\FLEXlm License Manager' /v SW_D_LICENSE_FILE /t REG_SZ /d '25734@localhost' /f
"${WINE}" reg add 'HKLM\System\CurrentControlSet\Control\Session Manager\Environment' /v SOLIDWORKS_LICENSE_FILE /t REG_SZ /d '25734@localhost' /f
"${WINE}" reg add 'HKLM\System\CurrentControlSet\Control\Session Manager\Environment' /v SW_D_LICENSE_FILE /t REG_SZ /d '25734@localhost' /f

echo "[INFO] 同步注册表数据并校验..."
"${CX_ROOT}/bin/wineserver" -w || true

if grep -i -q "SolidWorks" "${WORKSPACE_ROOT}/bottle/system.reg" && \
   grep -i -q "SolidWorks" "${WORKSPACE_ROOT}/bottle/user.reg"; then
    echo "[SUCCESS] SolidWorks 注册表项校验成功！"
else
    echo "[ERROR] 注册表校验失败，请检查 system.reg 与 user.reg" >&2
    exit 1
fi
