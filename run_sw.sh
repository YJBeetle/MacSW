#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export CX_ROOT="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
export CX_BOTTLE="SolidWorks2025"
export PATH="${CX_ROOT}/bin:${PATH}"

WINE="${CX_ROOT}/bin/wine"
SW_DIR="${WORKSPACE_ROOT}/bottle/drive_c/Program Files/SOLIDWORKS Corp/SOLIDWORKS"
LOG_DIR="${WORKSPACE_ROOT}/scratch"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/sw_launch.log"

echo "=========================================="
echo "准备启动 SolidWorks 2025 (Wine/CrossOver)"
echo "容器名称: ${CX_BOTTLE}"
echo "工作目录: ${SW_DIR}"
echo "调试日志: ${LOG_FILE}"
echo "=========================================="

export LANG="zh_CN.UTF-8"
export LC_ALL="zh_CN.UTF-8"

# 1. 确保 FlexNet 许可服务正常运行
"${WORKSPACE_ROOT}/scripts/manage_license.sh" start
"${WORKSPACE_ROOT}/scripts/setup_fonts.sh"

# 2. 图形与运行库转译环境配置 (CrossOver D3DMetal / DXVK / Native VC++)
export WINEDLLOVERRIDES="concrt140=n,b;msvcp140=n,b;msvcp140_1=n,b;msvcp140_2=n,b;msvcp140_atomic_wait=n,b;msvcp140_codecvt_ids=n,b;vcruntime140=n,b;vcruntime140_1=n,b;vcomp140=n,b;mfc140u=n,b;d3dcompiler_47=n,b;d3d11=n,b;dxgi=n,b"
export DXVK_LOG_LEVEL="info"
export MVK_CONFIG_LOG_LEVEL="2"

# 3. 启动 UI 守护进程（自动修复 3D 视口重叠、MFC 停靠面板黑屏与通用控件主题）
echo "[INFO] 启动 SolidWorks UI 守护进程 (sw_ui_daemon)..."
"${WINE}" "${WORKSPACE_ROOT}/scripts/sw_ui_daemon.exe" --watch >/dev/null 2>&1 &
DAEMON_PID=$!
trap 'kill ${DAEMON_PID} 2>/dev/null || true' EXIT

# 4. 调试输出配置 (默认记录 warn/err/fixme)
export WINEDEBUG="${WINEDEBUG:-+loaddll,-all,fixme-all}"

cd "${SW_DIR}"
echo "[INFO] 正在拉起 SLDWORKS.exe..."
"${WINE}" "${SW_DIR}/SLDWORKS.exe" "$@" 2>&1 | tee "${LOG_FILE}"
