#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CX_ROOT="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
export CX_BOTTLE="SolidWorks2025"
export PATH="${CX_ROOT}/bin:${PATH}"

WINE="${CX_ROOT}/bin/wine"
FLEX_DIR="${WORKSPACE_ROOT}/bottle/drive_c/opt/SolidWorks_Flexnet_Server"
LOG_FILE="${WORKSPACE_ROOT}/scratch/flexnet.log"
mkdir -p "${WORKSPACE_ROOT}/scratch"

MODE="${1:-status}"

case "${MODE}" in
    start)
        echo "[INFO] 检查 FlexNet 许可服务..."
        if nc -z 127.0.0.1 25734 2>/dev/null; then
            echo "[SUCCESS] FlexNet 许可服务已在运行中 (25734 连通)"
            exit 0
        fi
        
        # 寻找可用的 FlexNet 服务目录
        for CANDIDATE in "${FLEX_DIR}" "${WORKSPACE_ROOT}/DS.SolidWorks.2025.SP5.0.Premium-SSQ/crack/SolidWorks_Flexnet_Server" "${WORKSPACE_ROOT}/C/opt/SolidWorks_Flexnet_Server"; do
            if [ -f "${CANDIDATE}/lmgrd.exe" ]; then
                FLEX_DIR="${CANDIDATE}"
                break
            fi
        done
        
        if [ ! -f "${FLEX_DIR}/lmgrd.exe" ]; then
            echo "[ERROR] 未找到 FlexNet 许可服务器目录"
            exit 1
        fi

        echo "[INFO] 启动本地 FlexNet 守护进程 (lmgrd.exe)..."
        cd "${FLEX_DIR}"
        nohup "${WINE}" "${FLEX_DIR}/lmgrd.exe" -c "${FLEX_DIR}/sw_d_SSQ.lic" -l "${LOG_FILE}" >/dev/null 2>&1 &
            
            # 等待服务就绪
            echo "[INFO] 等待许可服务初始化..."
            for i in {1..10}; do
                sleep 1
                if "${WINE}" "${FLEX_DIR}/lmutil.exe" lmstat -c 25734@127.0.0.1 >/dev/null 2>&1; then
                    echo "[SUCCESS] FlexNet 许可服务启动成功并就绪！"
                    exit 0
                fi
            done
            echo "[WARN] 服务已启动，但端口响应较慢，请查看 ${LOG_FILE}"
        ;;
    status)
        echo "[INFO] 查询 FlexNet 许可服务状态..."
        cd "${FLEX_DIR}"
        "${WINE}" "${FLEX_DIR}/lmutil.exe" lmstat -c 25734@127.0.0.1 -a || true
        ;;
    stop)
        echo "[INFO] 停止 FlexNet 服务..."
        cd "${FLEX_DIR}"
        "${WINE}" "${FLEX_DIR}/lmutil.exe" lmdown -c 25734@127.0.0.1 -q -force || true
        echo "[SUCCESS] 停止指令已发出"
        ;;
    point-vm)
        TARGET_IP="${2:?请提供虚拟机 IP，例如: ./scripts/manage_license.sh point-vm 10.211.55.3}"
        echo "[INFO] 将许可服务器指向虚拟机: 25734@${TARGET_IP}"
        "${WINE}" reg add 'HKLM\System\CurrentControlSet\Control\Session Manager\Environment' /v SOLIDWORKS_LICENSE_FILE /t REG_SZ /d "25734@${TARGET_IP}" /f
        "${WINE}" reg add 'HKLM\System\CurrentControlSet\Control\Session Manager\Environment' /v SW_D_LICENSE_FILE /t REG_SZ /d "25734@${TARGET_IP}" /f
        "${WINE}" reg add 'HKLM\SOFTWARE\FLEXlm License Manager' /v SW_D_LICENSE_FILE /t REG_SZ /d "25734@${TARGET_IP}" /f
        "${WINE}" reg add 'HKCU\SOFTWARE\FLEXlm License Manager' /v SW_D_LICENSE_FILE /t REG_SZ /d "25734@${TARGET_IP}" /f
        echo "[SUCCESS] 已更新注册表许可指向为: 25734@${TARGET_IP}"
        ;;
    *)
        echo "Usage: $0 {start|status|stop|point-vm <ip>}"
        exit 1
        ;;
esac
