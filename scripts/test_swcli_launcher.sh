#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
# Match the launcher's physical paths (macOS /var and /tmp are directory links).
TEST_ROOT="$(cd "${TEST_ROOT}" && pwd -P)"
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
mkdir -p "${PREFIX}/dosdevices"
ln -s ../drive_c "${PREFIX}/dosdevices/c:"
ln -s / "${PREFIX}/dosdevices/z:"

cp "${WORKSPACE_ROOT}/scripts/swcli/sw-cli" "${CONTENTS_DIR}/MacOS/sw-cli"
cp "${WORKSPACE_ROOT}/scripts/swcli/swcli-daemon-utils" "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-daemon-utils"
chmod +x "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-daemon-utils"
cp "${WORKSPACE_ROOT}/scripts/swcli/swcli-path" \
    "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path"
cp "${WORKSPACE_ROOT}/scripts/swcli/swcli_path.py" \
    "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli_path.py"
touch "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli_path.exe"
touch "${PREFIX}/drive_c/MacSW/Python311/python.exe"
touch "${PREFIX}/drive_c/MacSW/Python311/pythonw.exe"

cat > "${CONTENTS_DIR}/MacOS/MacSW" <<'EOF'
#!/usr/bin/env bash
printf 'prepare prefix=%s args=%s\n' "${MACSW_WINEPREFIX:-}" "$*" >> "${SWCLI_TEST_LOG}"
exit "${SWCLI_TEST_PREPARE_STATUS:-0}"
EOF
cat > "${CONTENTS_DIR}/Frameworks/wine/bin/wineloader" <<'EOF'
#!/usr/bin/env bash
printf 'windows translator=%s aot=%s overrides=%s lang=%s lc_all=%s loader=%s server=%s args=%s\n' \
    "${SWCLI_PATH_TRANSLATE_CMD:-}" "${WINE_MONO_AOT:-}" "${WINEDLLOVERRIDES:-}" \
    "${LANG:-}" "${LC_ALL:-}" "${WINELOADER:-}" "${WINESERVER:-}" "$*" >> "${SWCLI_TEST_LOG}"
printf 'delegated=%s\n' "${SWCLI_DAEMON_UTILS_ACTIVE:-}" >> "${SWCLI_TEST_LOG}"
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
if [[ "${1:-}" == "-I" ]]; then shift; fi
if [[ "${1:-}" != "-B" ]]; then
    echo 'bundled native Python must explicitly disable bytecode' >&2
    exit 97
fi
shift
if [[ "${1:-}" == */swcli_path.py ]]; then
    exec "${SWCLI_TEST_PYTHON}" -B "$@"
fi
if [[ "${1:-}" == */swcli_runtime.py ]]; then
    printf 'sync prefix=%s\n' "${WINEPREFIX}" >> "${SWCLI_TEST_LOG}"
    exit "${SWCLI_TEST_SYNC_STATUS:-0}"
fi
if [[ "${1:-}" == */wine_runtime.py ]]; then
    if [[ "${2:-}" == "check" ]]; then
        exit "${SWCLI_TEST_WINE_STATUS:-0}"
    fi
    while [[ "${1:-}" != "--" ]]; do shift; done
    shift
    exec "$@"
fi
printf 'native translator=%s args=%s\n' "${SWCLI_PATH_TRANSLATE_CMD:-}" "$*" >> "${SWCLI_TEST_LOG}"
printf 'utils=%s\n' "${SWCLI_DAEMON_UTILS:-}" >> "${SWCLI_TEST_LOG}"
EOF
chmod +x \
    "${CONTENTS_DIR}/MacOS/sw-cli" \
    "${CONTENTS_DIR}/MacOS/MacSW" \
    "${CONTENTS_DIR}/Frameworks/wine/bin/wineloader" \
    "${CONTENTS_DIR}/Frameworks/wine/bin/wineserver" \
    "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" \
    "${CONTENTS_DIR}/Resources/SWCLI/runtime/PythonNative/bin/python3"

export MACSW_WINEPREFIX="${PREFIX}"
export SWCLI_TEST_LOG="${LOG_FILE}"
export SWCLI_TEST_PYTHON="$(command -v python3)"
LAUNCHER="${CONTENTS_DIR}/MacOS/sw-cli"

UTILS="${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-daemon-utils"
# Public CLI parsing stays in native Python, including leading global options.
for arguments in '--help' 'version --json' 'daemon status --json' 'daemon status --details --json' 'daemon stop --json' 'daemon start --json' 'doctor --json' 'mcp serve'; do
    : > "${LOG_FILE}"
    # Intentional word splitting of fixed test literals only.
    SWCLI_TEST_WINE_STATUS=1 SWCLI_TEST_SYNC_STATUS=1 "${LAUNCHER}" ${arguments}
    grep -Fq -- "-m swcli ${arguments}" "${LOG_FILE}"
    grep -Fq "utils=${UTILS}" "${LOG_FILE}"
    ! grep -Fq 'windows ' "${LOG_FILE}"
    ! grep -Fq 'sync prefix=' "${LOG_FILE}"
    ! grep -Fq 'prepare prefix=' "${LOG_FILE}"
done
: > "${LOG_FILE}"
"${LAUNCHER}" --endpoint 127.0.0.1:19500 daemon start --json
grep -Fq -- '-m swcli --endpoint 127.0.0.1:19500 daemon start --json' "${LOG_FILE}"
: > "${LOG_FILE}"
SWCLI_DAEMON_UTILS='/custom/daemon utils' "${LAUNCHER}" mcp serve
grep -Fq 'utils=/custom/daemon utils' "${LOG_FILE}"

# Utilities receive a dedicated action and choose only the Windows runtime.
: > "${LOG_FILE}"
if SWCLI_TEST_WINE_STATUS=1 "${UTILS}" doctor --json; then
    echo 'utils ignored Wine runtime preflight' >&2; exit 1
fi
test ! -s "${LOG_FILE}"
: > "${LOG_FILE}"
if SWCLI_TEST_SYNC_STATUS=1 "${UTILS}" start --json; then
    echo 'utils ignored runtime synchronization failure' >&2; exit 1
fi
! grep -Fq 'windows ' "${LOG_FILE}"
: > "${LOG_FILE}"
STATUS_OUTPUT="$("${UTILS}" start --endpoint 127.0.0.1:19500 --json)"
test "${STATUS_OUTPUT}" = '{"mock":true}'
grep -Fq 'windows translator=Z:' "${LOG_FILE}"
grep -Fq 'pythonw.exe -c' "${LOG_FILE}"
grep -Fq 'daemon start --endpoint 127.0.0.1:19500 --json' "${LOG_FILE}"
grep -Fq 'delegated=1' "${LOG_FILE}"
grep -Fq "prepare prefix=${PREFIX} args=--prepare-swcli-daemon" "${LOG_FILE}"
test "$(grep -c 'prepare prefix=' "${LOG_FILE}")" = 1
test "$(grep -n 'prepare prefix=' "${LOG_FILE}" | cut -d: -f1)" -lt "$(grep -n 'windows translator=' "${LOG_FILE}" | cut -d: -f1)"
grep -Fq 'aot=none' "${LOG_FILE}"
grep -Fq 'overrides=atiadlxx=d;winemenubuilder.exe=d;concrt140=n,b;msvcp140=n,b;msvcp140_1=n,b;msvcp140_2=n,b;msvcp140_atomic_wait=n,b;msvcp140_codecvt_ids=n,b;vcruntime140=n,b;vcruntime140_1=n,b;vcomp140=n,b;mfc140u=n,b' "${LOG_FILE}"
grep -Fq 'lang=zh_CN.UTF-8 lc_all=zh_CN.UTF-8' "${LOG_FILE}"
grep -Fq "loader=${CONTENTS_DIR}/Frameworks/wine/bin/wineloader server=${CONTENTS_DIR}/Frameworks/wine/bin/wineserver" "${LOG_FILE}"
! grep -Fq 'native ' "${LOG_FILE}"
: > "${LOG_FILE}"
"${UTILS}" serve --port 18496
grep -Fq "prepare prefix=${PREFIX} args=--prepare-swcli-daemon" "${LOG_FILE}"
grep -Fq 'C:\MacSW\Python311\python.exe -m swcli daemon serve --port 18496' "${LOG_FILE}"
! grep -Fq 'pythonw.exe' "${LOG_FILE}"
: > "${LOG_FILE}"
"${LAUNCHER}" document list --json
! grep -Fq 'windows ' "${LOG_FILE}"
grep -Fq -- '-m swcli document list --json' "${LOG_FILE}"

# Only explicit lifecycle start/serve/restart prepares the native prerequisite.
: > "${LOG_FILE}"
"${UTILS}" restart --json >/dev/null
grep -Fq "prepare prefix=${PREFIX} args=--prepare-swcli-daemon" "${LOG_FILE}"
: > "${LOG_FILE}"
"${UTILS}" doctor --json >/dev/null
! grep -Fq 'prepare prefix=' "${LOG_FILE}"
: > "${LOG_FILE}"
if SWCLI_TEST_PREPARE_STATUS=42 "${UTILS}" start --json; then
    echo 'utils ignored native daemon preparation failure' >&2; exit 1
else
    test "$?" = 42
fi
grep -Fq 'prepare prefix=' "${LOG_FILE}"
! grep -Fq 'windows translator=' "${LOG_FILE}"

TMP_PHYSICAL="$(cd /tmp && pwd -P)"
EXPECTED_TMP="Z:${TMP_PHYSICAL//\//\\}\\model.SLDPRT"
test "$("${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" /tmp/model.SLDPRT)" = "${EXPECTED_TMP}"
test "$(cd /tmp && "${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" model.SLDPRT)" = "${EXPECTED_TMP}"
test "$("${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" 'C:\model.SLDPRT')" = 'C:\model.SLDPRT'
test "$("${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" \
    "${PREFIX}/drive_c/models/part with spaces.SLDPRT")" = 'C:\models\part with spaces.SLDPRT'

# The installed PATH command must locate this App through absolute, relative,
# and directory symlinks, preserve cwd, and forward quoted arguments unchanged.
GLOBAL_BIN="${TEST_ROOT}/global bin ' 中文"
mkdir -p "${GLOBAL_BIN}"
ln -s "${LAUNCHER}" "${GLOBAL_BIN}/sw-cli"
: > "${LOG_FILE}"
PATH="${GLOBAL_BIN}:${PATH}" sw-cli document inspect --document active --json
grep -Fq -- '-m swcli document inspect --document active --json' "${LOG_FILE}"
grep -Fq "native translator=${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" "${LOG_FILE}"
rm "${GLOBAL_BIN}/sw-cli"
ln -s '../MacSW.app/Contents/MacOS/sw-cli' "${GLOBAL_BIN}/launcher"
ln -s launcher "${GLOBAL_BIN}/sw-cli"
ln -s "${GLOBAL_BIN}" "${TEST_ROOT}/bin-alias"
: > "${LOG_FILE}"
(cd "${PREFIX}" && "${TEST_ROOT}/bin-alias/sw-cli" document inspect --document 'a file;$(literal)' --json)
grep -Fq -- '-m swcli document inspect --document a file;$(literal) --json' "${LOG_FILE}"
grep -Fq "native translator=${CONTENTS_DIR}/Resources/SWCLI/bin/swcli-path" "${LOG_FILE}"
grep -Fq "utils=${UTILS}" "${LOG_FILE}"

# Lifecycle paths also use real bottle mappings, rather than hard-coding Z:.
rm "${PREFIX}/dosdevices/z:"
ln -s "${TEST_ROOT}" "${PREFIX}/dosdevices/h:"
mkdir -p "${PREFIX}/drive_c/tmp"
: > "${LOG_FILE}"
(cd "${PREFIX}/drive_c" && TMPDIR="${PREFIX}/drive_c/tmp/" "${UTILS}" serve --port 18496)
grep -Fq 'windows translator=H:\MacSW.app\Contents\Resources\SWCLI\bin\swcli_path.exe' "${LOG_FILE}"
! grep -Fq 'translator=Z:' "${LOG_FILE}"
