#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOTSTRAP_DIR="${WORKSPACE_ROOT}/macos/Bootstrap"
OUTPUT_DIR="${WORKSPACE_ROOT}/build/bootstrap"

mkdir -p "${OUTPUT_DIR}"

echo "==> [MacSW] 正在使用系统 swiftc 编译原生 macOS Bootstrap UI..."

SWIFT_FILES=(
    "${BOOTSTRAP_DIR}/AppState.swift"
    "${BOOTSTRAP_DIR}/Services/IsoService.swift"
    "${BOOTSTRAP_DIR}/Services/WineService.swift"
    "${BOOTSTRAP_DIR}/Services/PrerequisiteService.swift"
    "${BOOTSTRAP_DIR}/Services/CompanionFileService.swift"
    "${BOOTSTRAP_DIR}/Views/WizardView.swift"
    "${BOOTSTRAP_DIR}/Views/DashboardView.swift"
    "${BOOTSTRAP_DIR}/Views/MainView.swift"
    "${BOOTSTRAP_DIR}/main.swift"
)

TARGET_ARCH="$(uname -m)"

swiftc -O \
    -target "${TARGET_ARCH}-apple-macos13.0" \
    "${SWIFT_FILES[@]}" \
    -o "${OUTPUT_DIR}/MacSW_Bootstrap"

echo "==> [SUCCESS] 原生 Mach-O 二进制构建成功: ${OUTPUT_DIR}/MacSW_Bootstrap"
file "${OUTPUT_DIR}/MacSW_Bootstrap"
