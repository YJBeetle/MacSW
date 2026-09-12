#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_FILE="${WORKSPACE_ROOT}/scripts/sw_ui_daemon.c"
OUTPUT_DIR="${WORKSPACE_ROOT}/build/native"
OUTPUT_FILE="${OUTPUT_DIR}/sw_ui_daemon.exe"
COMPILER="${MINGW_CC:-x86_64-w64-mingw32-gcc}"

if ! command -v "${COMPILER}" >/dev/null 2>&1; then
    echo "The x86_64 MinGW compiler is required. Install it with: brew install mingw-w64" >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

"${COMPILER}" \
    -municode \
    -mwindows \
    -O2 \
    -Wall \
    -Wextra \
    -Werror \
    -Wl,--no-insert-timestamp \
    -o "${OUTPUT_FILE}.new" \
    "${SOURCE_FILE}" \
    -luser32

file "${OUTPUT_FILE}.new" | grep -q 'PE32+ executable.*x86-64'
mv "${OUTPUT_FILE}.new" "${OUTPUT_FILE}"
echo "==> Native SolidWorks UI daemon built: ${OUTPUT_FILE}"
