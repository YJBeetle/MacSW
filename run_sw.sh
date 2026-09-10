#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -z "${WINEPREFIX:-}" ]; then
    if [ -d "${HOME}/Library/Application Support/MacSW/bottle" ]; then
        export WINEPREFIX="${HOME}/Library/Application Support/MacSW/bottle"
    else
        export WINEPREFIX="${WORKSPACE_ROOT}/bottle"
    fi
fi

LOG_DIR="${HOME}/Library/Application Support/MacSW/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/sw_launch.log"

# 优先使用 MacSW 内置定制 Wine，其次使用 CrossOver wineloader，最后回退系统 wine
if [ -x "${WORKSPACE_ROOT}/build/app/MacSW.app/Contents/Frameworks/wine/bin/wine" ]; then
    WINE="${WORKSPACE_ROOT}/build/app/MacSW.app/Contents/Frameworks/wine/bin/wine"
elif [ -x "${WORKSPACE_ROOT}/dist/wine-crossover-macsw-x86_64/bin/wine" ]; then
    WINE="${WORKSPACE_ROOT}/dist/wine-crossover-macsw-x86_64/bin/wine"
elif [ -x "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wineloader" ]; then
    WINE="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wineloader"
else
    WINE="wine"
fi

SW_DIR=""
if [ $# -ge 1 ] && [ -f "$1" ]; then
    TARGET_EXE="$1"
    SW_DIR="$(dirname "${TARGET_EXE}")"
    shift
fi

if [ -z "$SW_DIR" ]; then
    REG_FILE="${WINEPREFIX}/system.reg"
    if [ -f "$REG_FILE" ]; then
        REG_VAL=$(grep -i '"SolidWorks Folder"=' "$REG_FILE" | head -n 1 | cut -d'=' -f2- | tr -d '"\r\n' | sed 's/\\\\/\//g' | sed 's/^[cC]:\///' | sed 's/\/$//')
        if [ -n "$REG_VAL" ] && [ -f "${WINEPREFIX}/drive_c/${REG_VAL}/SLDWORKS.exe" ]; then
            SW_DIR="${WINEPREFIX}/drive_c/${REG_VAL}"
        fi
    fi
fi

if [ -z "$SW_DIR" ]; then
    FOUND=$(find "${WINEPREFIX}/drive_c" -iname "SLDWORKS.exe" 2>/dev/null | head -n 1)
    if [ -n "$FOUND" ]; then
        SW_DIR="$(dirname "$FOUND")"
    fi
fi

if [ -z "$SW_DIR" ]; then
    echo "[ERROR] 未能定位到 SLDWORKS.exe，容器路径: ${WINEPREFIX}" | tee -a "${LOG_FILE}"
    exit 1
fi

echo "=========================================="
echo "准备启动 SolidWorks 2025 (MacSW 独立 Wine 容器)"
echo "容器路径: ${WINEPREFIX}"
echo "工作目录: ${SW_DIR}"
echo "调试日志: ${LOG_FILE}"
echo "=========================================="

export LANG="zh_CN.UTF-8"
export LC_ALL="zh_CN.UTF-8"
export SOLIDWORKS_LICENSE_FILE="25734@127.0.0.1;25734@localhost"
export SW_D_LICENSE_FILE="25734@127.0.0.1;25734@localhost"

# 1. 确保 FlexNet 许可服务正常运行
if nc -z 127.0.0.1 25734 2>/dev/null; then
    echo "[INFO] FlexNet 许可服务运行正常 (25734 连通)"
else
    FLEX_DIR="${WINEPREFIX}/drive_c/opt/SolidWorks_Flexnet_Server"
    if [ -f "${FLEX_DIR}/lmgrd.exe" ]; then
        echo "[INFO] 启动本地 FlexNet 守护进程..."
        (cd "${FLEX_DIR}" && nohup "${WINE}" "${FLEX_DIR}/lmgrd.exe" -c "${FLEX_DIR}/sw_d_SSQ.lic" -l "${WORKSPACE_ROOT}/scratch/flexnet.log" >/dev/null 2>&1 &)
        sleep 2
    fi
fi
"${WINE}" regedit "${WORKSPACE_ROOT}/scripts/disable_login_mgr.reg" >/dev/null 2>&1 || true


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
