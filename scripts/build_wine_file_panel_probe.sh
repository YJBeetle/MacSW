#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT/build/native"
for ARCH in x86_64 i686; do
    "${ARCH}-w64-mingw32-gcc" -Os -municode -Wall -Wextra -Werror \
        "$ROOT/native/wine_file_panel_probe.c" -o "$ROOT/build/native/wine_file_panel_probe-${ARCH}.exe" \
        -lcomdlg32 -lole32 -lshell32 -luuid
done
