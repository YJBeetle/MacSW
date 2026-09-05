#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRIVE_C="${WORKSPACE_ROOT}/bottle/drive_c"

echo "[INFO] 对齐虚拟 C 盘文件系统映射..."
mkdir -p "${DRIVE_C}/Program Files/SOLIDWORKS Corp"
mkdir -p "${DRIVE_C}/ProgramData"
mkdir -p "${DRIVE_C}/opt"

# 1. 映射 Program Files/SOLIDWORKS Corp/SOLIDWORKS
SW_CORP_TARGET="${DRIVE_C}/Program Files/SOLIDWORKS Corp/SOLIDWORKS"
if [ -L "${SW_CORP_TARGET}" ] || [ -d "${SW_CORP_TARGET}" ]; then
    echo "[INFO] 已存在 SW 目标路径: ${SW_CORP_TARGET}"
else
    echo "[INFO] 建立软链接: SOLIDWORKS -> ${WORKSPACE_ROOT}/C/Program Files/SOLIDWORKS Corp/SOLIDWORKS"
    ln -s "${WORKSPACE_ROOT}/C/Program Files/SOLIDWORKS Corp/SOLIDWORKS" "${SW_CORP_TARGET}"
fi

# 2. 映射 ProgramData/SOLIDWORKS
PD_TARGET="${DRIVE_C}/ProgramData/SOLIDWORKS"
if [ -L "${PD_TARGET}" ] || [ -d "${PD_TARGET}" ]; then
    echo "[INFO] 已存在 ProgramData/SOLIDWORKS"
else
    echo "[INFO] 建立软链接: ProgramData/SOLIDWORKS -> ${WORKSPACE_ROOT}/C/ProgramData/SOLIDWORKS"
    ln -s "${WORKSPACE_ROOT}/C/ProgramData/SOLIDWORKS" "${PD_TARGET}"
fi

# 3. 映射 SOLIDWORKS Data
DATA_TARGET="${DRIVE_C}/SOLIDWORKS Data"
if [ -L "${DATA_TARGET}" ] || [ -d "${DATA_TARGET}" ]; then
    echo "[INFO] 已存在 SOLIDWORKS Data"
else
    echo "[INFO] 建立软链接: SOLIDWORKS Data -> ${WORKSPACE_ROOT}/C/SOLIDWORKS Data"
    ln -s "${WORKSPACE_ROOT}/C/SOLIDWORKS Data" "${DATA_TARGET}"
fi

# 4. 映射 SolidWorks_Flexnet_Server
FLEX_TARGET="${DRIVE_C}/opt/SolidWorks_Flexnet_Server"
if [ -L "${FLEX_TARGET}" ] || [ -d "${FLEX_TARGET}" ]; then
    echo "[INFO] 已存在 SolidWorks_Flexnet_Server"
else
    echo "[INFO] 建立软链接: SolidWorks_Flexnet_Server -> ${WORKSPACE_ROOT}/C/opt/SolidWorks_Flexnet_Server"
    ln -s "${WORKSPACE_ROOT}/C/opt/SolidWorks_Flexnet_Server" "${FLEX_TARGET}"
fi

# 验证 SLDWORKS.exe 可达性
SLDWORKS_EXE="${DRIVE_C}/Program Files/SOLIDWORKS Corp/SOLIDWORKS/SLDWORKS.exe"
if [ -f "${SLDWORKS_EXE}" ]; then
    echo "[SUCCESS] 主程序路径可达: ${SLDWORKS_EXE}"
else
    echo "[ERROR] 未找到主程序: ${SLDWORKS_EXE}" >&2
    exit 1
fi
