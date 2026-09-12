#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/config.sh"
DIST_DIR="${WORKSPACE_ROOT}/dist"
mkdir -p "${DIST_DIR}"

download_verified() {
    local label="$1"
    local url="$2"
    local destination="$3"
    local expected_sha256="$4"
    local actual_sha256

    if [ ! -f "${destination}" ]; then
        echo "==> Downloading ${label}..."
        curl -fL --retry 3 "${url}" -o "${destination}.download"
        actual_sha256="$(shasum -a 256 "${destination}.download" | awk '{print $1}')"
        if [ "${actual_sha256}" != "${expected_sha256}" ]; then
            echo "${label} checksum mismatch" >&2
            rm -f -- "${destination}.download"
            exit 1
        fi
        mv "${destination}.download" "${destination}"
    fi

    actual_sha256="$(shasum -a 256 "${destination}" | awk '{print $1}')"
    if [ "${actual_sha256}" != "${expected_sha256}" ]; then
        echo "${label} checksum mismatch: ${destination}" >&2
        exit 1
    fi
}

fetch_runtime() {
    download_verified "Gcenx Wine ${WINE_VERSION} runtime" "${WINE_RUNTIME_URL}" \
        "${DIST_DIR}/${WINE_RUNTIME_ASSET}" "${WINE_RUNTIME_SHA256}"
}

fetch_wine_source() {
    download_verified "Wine ${WINE_VERSION} source" "${WINE_SOURCE_URL}" \
        "${DIST_DIR}/${WINE_SOURCE_ASSET}" "${WINE_SOURCE_SHA256}"
}

fetch_mono_patch() {
    local mono_dir="${DIST_DIR}/${MONO_PATCH_RELEASE}"
    mkdir -p "${mono_dir}"
    download_verified "Wine-Mono ${WINE_MONO_VERSION} x86 patch" "${MONO_PATCH_URL}" \
        "${mono_dir}/libmono-2.0-x86.dll" "${MONO_PATCH_SHA256}"
}

fetch_seven_zip() {
    local archive="${DIST_DIR}/${SEVEN_Z_ARCHIVE_ASSET}"
    download_verified "7-Zip ${SEVEN_Z_VERSION}" "${SEVEN_Z_URL}" \
        "${archive}" "${SEVEN_Z_SHA256}"
    if [ ! -x "${DIST_DIR}/7zz" ]; then
        tar -xJf "${archive}" -C "${DIST_DIR}" 7zz
        chmod +x "${DIST_DIR}/7zz"
    fi
}

case "${1:-all}" in
    all)
        fetch_runtime
        fetch_wine_source
        fetch_mono_patch
        fetch_seven_zip
        ;;
    runtime) fetch_runtime ;;
    wine-source) fetch_wine_source ;;
    mono) fetch_mono_patch ;;
    seven-zip) fetch_seven_zip ;;
    *)
        echo "Usage: $0 [all|runtime|wine-source|mono|seven-zip]" >&2
        exit 2
        ;;
esac
