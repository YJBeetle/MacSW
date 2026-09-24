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
touch "${PREFIX}/drive_c/MacSW/Python311/pythonw.exe"

cat > "${CONTENTS_DIR}/Frameworks/wine/bin/wineloader" <<'EOF'
#!/usr/bin/env bash
printf 'windows translator=%s aot=%s overrides=%s lang=%s lc_all=%s loader=%s server=%s args=%s\n' \
    "${SWCLI_PATH_TRANSLATE_CMD:-}" "${WINE_MONO_AOT:-}" "${WINEDLLOVERRIDES:-}" \
    "${LANG:-}" "${LC_ALL:-}" "${WINELOADER:-}" "${WINESERVER:-}" "$*" >> "${SWCLI_TEST_LOG}"
if [[ "${1:-}" == *pythonw.exe && "${2:-}" == "-c" ]]; then
    output="${4#Z:}"
    output="${output//\\//}"
    printf '{"mock":true}\n' > "${output}"
fi
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
STATUS_OUTPUT="$("${LAUNCHER}" daemon status --json)"
test "${STATUS_OUTPUT}" = '{"mock":true}'
grep -Fq 'windows translator=Z:' "${LOG_FILE}"
grep -Fq 'pythonw.exe -c' "${LOG_FILE}"
grep -Fq 'aot=none' "${LOG_FILE}"
grep -Fq 'overrides=atiadlxx=d;concrt140=n,b;msvcp140=n,b;msvcp140_1=n,b;msvcp140_2=n,b;msvcp140_atomic_wait=n,b;msvcp140_codecvt_ids=n,b;vcruntime140=n,b;vcruntime140_1=n,b;vcomp140=n,b;mfc140u=n,b' "${LOG_FILE}"
grep -Fq 'lang=zh_CN.UTF-8 lc_all=zh_CN.UTF-8' "${LOG_FILE}"
grep -Fq "loader=${CONTENTS_DIR}/Frameworks/wine/bin/wineloader server=${CONTENTS_DIR}/Frameworks/wine/bin/wineserver" "${LOG_FILE}"
! grep -Fq 'native ' "${LOG_FILE}"

: > "${LOG_FILE}"
"${LAUNCHER}" document list --json
! grep -Fq 'windows ' "${LOG_FILE}"
grep -Fq 'native translator=' "${LOG_FILE}"
grep -Fq -- '-m swcli document list --json' "${LOG_FILE}"

: > "${LOG_FILE}"
"${LAUNCHER}" part create-box /tmp/box.SLDPRT --width-mm 1 --height-mm 2 --depth-mm 3 --json
! grep -Fq 'windows ' "${LOG_FILE}"
grep -Fq -- '-m swcli part create-box' "${LOG_FILE}"

test "$("${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" /tmp/model.SLDPRT)" = 'Z:\tmp\model.SLDPRT'
test "$(cd /tmp && "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" model.SLDPRT)" = 'Z:\tmp\model.SLDPRT'
test "$("${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" 'C:\model.SLDPRT')" = 'C:\model.SLDPRT'
