#!/usr/bin/env bash
set -euo pipefail
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "${WORKSPACE_ROOT}/build/native"
for ARCH in x86_64 i686; do
    "${ARCH}-w64-mingw32-gcc" -Os -municode -Wall -Wextra -Werror \
        "${WORKSPACE_ROOT}/native/wine_file_manager_probe.c" \
        -o "${WORKSPACE_ROOT}/build/native/wine_file_manager_probe-${ARCH}.exe" \
        -lshell32 -lole32 -luuid
done
