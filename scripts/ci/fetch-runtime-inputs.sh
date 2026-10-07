#!/usr/bin/env bash
set -Eeuo pipefail

test "${GITHUB_ACTIONS:-}" = true || { echo 'CI runner required' >&2; exit 1; }
: "${RUNNER_TEMP:?}" "${RCLONE_CONFIG_B64:?}" "${MACSW_ASSETS_PATH:?}"
private_dir="${RUNNER_TEMP}/MacSW-runtime/private"
mkdir -p "${private_dir}"
chmod 700 "${private_dir}"
config_file="$(mktemp "${private_dir}/rclone.XXXXXX")"
trap 'rm -f -- "${config_file}"' EXIT
printf '%s' "${RCLONE_CONFIG_B64}" | base64 --decode > "${config_file}"
chmod 600 "${config_file}"
unset RCLONE_CONFIG_B64
rclone --config "${config_file}" listremotes 2> "${private_dir}/download.log" | grep -qx 'gdrive:'
# Small private runtime fixtures only. The large ISO is mounted by mount-install.py.
if ! rclone --config "${config_file}" copy "gdrive:${MACSW_ASSETS_PATH}" "${private_dir}/assets" \
    >> "${private_dir}/download.log" 2>&1; then
    echo 'Private runtime fixture download failed; no credentials or download diagnostics are published.' >&2
    exit 1
fi
test -d "${private_dir}/assets/SOLIDWORKS Corp/SOLIDWORKS"
