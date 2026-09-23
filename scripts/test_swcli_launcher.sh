#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TEST_ROOT}"' EXIT

CONTENTS_DIR="${TEST_ROOT}/MacSW.app/Contents"
LOG_FILE="${TEST_ROOT}/calls.log"
PREFIX="${TEST_ROOT}/bottle"
mkdir -p \
    "${CONTENTS_DIR}/MacOS" \
    "${CONTENTS_DIR}/Frameworks/wine/bin" \
    "${CONTENTS_DIR}/Resources/SWCLI/bin" \
    "${CONTENTS_DIR}/Resources/SWCLI/runtime/PythonNative/bin" \
    "${CONTENTS_DIR}/Resources/SWCLI/runtime/PythonNative/lib/python3.11/site-packages" \
    "${PREFIX}/drive_c/MacSW/Python311"

cp "${WORKSPACE_ROOT}/scripts/swcli/sw-cli" "${CONTENTS_DIR}/MacOS/sw-cli"
cp "${WORKSPACE_ROOT}/scripts/swcli/swcli-path" \
    "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path"
touch "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli_path.exe"
touch "${PREFIX}/drive_c/MacSW/Python311/python.exe"

cat > "${CONTENTS_DIR}/Frameworks/wine/bin/wineloader" <<'EOF'
#!/usr/bin/env bash
printf 'windows translator=%s args=%s\n' "${SWCLI_PATH_TRANSLATE_CMD:-}" "$*" >> "${SWCLI_TEST_LOG}"
EOF
cat > "${CONTENTS_DIR}/Frameworks/wine/bin/wineserver" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "${CONTENTS_DIR}/Resources/SWCLI/runtime/PythonNative/bin/python3" <<'EOF'
#!/usr/bin/env bash
printf 'native translator=%s args=%s\n' "${SWCLI_PATH_TRANSLATE_CMD:-}" "$*" >> "${SWCLI_TEST_LOG}"
EOF
chmod +x \
    "${CONTENTS_DIR}/MacOS/sw-cli" \
    "${CONTENTS_DIR}/Frameworks/wine/bin/wineloader" \
    "${CONTENTS_DIR}/Frameworks/wine/bin/wineserver" \
    "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" \
    "${CONTENTS_DIR}/Resources/SWCLI/runtime/PythonNative/bin/python3"

export MACSW_WINEPREFIX="${PREFIX}"
export SWCLI_TEST_LOG="${LOG_FILE}"
LAUNCHER="${CONTENTS_DIR}/MacOS/sw-cli"

"${LAUNCHER}" --help
grep -Fq 'native translator=' "${LOG_FILE}"
! grep -Fq 'windows ' "${LOG_FILE}"

: > "${LOG_FILE}"
"${LAUNCHER}" daemon status --json
grep -Fq 'windows translator=Z:' "${LOG_FILE}"
! grep -Fq 'native ' "${LOG_FILE}"

: > "${LOG_FILE}"
"${LAUNCHER}" document list --json
grep -Fq 'windows translator=Z:' "${LOG_FILE}"
grep -Fq -- '-m swcli daemon start --visible --attach-existing --json' "${LOG_FILE}"
grep -Fq 'native translator=' "${LOG_FILE}"
grep -Fq -- '-m swcli document list --json' "${LOG_FILE}"

test "$("${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" /tmp/model.SLDPRT)" = 'Z:\tmp\model.SLDPRT'
test "$(cd /tmp && "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" model.SLDPRT)" = 'Z:\tmp\model.SLDPRT'
test "$("${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" 'C:\model.SLDPRT')" = 'C:\model.SLDPRT'
