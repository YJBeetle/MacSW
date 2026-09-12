#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/config.sh"
BOOTSTRAP_DIR="${WORKSPACE_ROOT}/macos/Bootstrap"
OUTPUT_DIR="${WORKSPACE_ROOT}/build/bootstrap"
MODULE_CACHE_DIR="${WORKSPACE_ROOT}/build/module-cache"
SWIFT_BUILD_DIR="${WORKSPACE_ROOT}/build/swift"
SWIFT_CACHE_DIR="${WORKSPACE_ROOT}/build/swiftpm/cache"
SWIFT_CONFIG_DIR="${WORKSPACE_ROOT}/build/swiftpm/config"
SWIFT_SECURITY_DIR="${WORKSPACE_ROOT}/build/swiftpm/security"

mkdir -p "${OUTPUT_DIR}" "${MODULE_CACHE_DIR}" "${SWIFT_BUILD_DIR}" \
    "${SWIFT_CACHE_DIR}" "${SWIFT_CONFIG_DIR}" "${SWIFT_SECURITY_DIR}"
export CLANG_MODULE_CACHE_PATH="${MODULE_CACHE_DIR}"
export SWIFT_MODULECACHE_PATH="${MODULE_CACHE_DIR}"

echo "==> [MacSW] 正在使用 SwiftPM 编译原生 macOS Bootstrap UI..."

swift build \
    --package-path "${BOOTSTRAP_DIR}" \
    --scratch-path "${SWIFT_BUILD_DIR}" \
    --cache-path "${SWIFT_CACHE_DIR}" \
    --config-path "${SWIFT_CONFIG_DIR}" \
    --security-path "${SWIFT_SECURITY_DIR}" \
    --configuration release \
    --product MacSW_Bootstrap

SWIFT_BIN_DIR="$(swift build \
    --package-path "${BOOTSTRAP_DIR}" \
    --scratch-path "${SWIFT_BUILD_DIR}" \
    --cache-path "${SWIFT_CACHE_DIR}" \
    --config-path "${SWIFT_CONFIG_DIR}" \
    --security-path "${SWIFT_SECURITY_DIR}" \
    --configuration release \
    --show-bin-path)"
cp "${SWIFT_BIN_DIR}/MacSW_Bootstrap" "${OUTPUT_DIR}/MacSW_Bootstrap"

echo "==> [SUCCESS] 原生 Mach-O 二进制构建成功: ${OUTPUT_DIR}/MacSW_Bootstrap"
file "${OUTPUT_DIR}/MacSW_Bootstrap"
