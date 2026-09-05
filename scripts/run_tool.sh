#!/usr/bin/env bash
set -e
export CX_ROOT="/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"
export CX_BOTTLE="SolidWorks2025"
export PATH="${CX_ROOT}/bin:${PATH}"

SRC="$1"
EXE="${SRC%.cs}.exe"

wine "C:\\windows\\Microsoft.NET\\Framework64\\v4.0.30319\\csc.exe" /nologo /out:"Z:${EXE}" "Z:${SRC}"
shift || true
wine "Z:${EXE}" "$@"
