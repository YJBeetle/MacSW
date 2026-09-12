#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/config.sh"
SOURCE_ARCHIVE="${WORKSPACE_ROOT}/dist/${WINE_SOURCE_ASSET}"
DRIVER_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0002-winemac-metal-layer-clipping.patch"
OUTPUT_DIR="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}"
OUTPUT_FILE="${OUTPUT_DIR}/winemac.so"
STAMP_FILE="${OUTPUT_DIR}/build-key"

if [ -x /opt/homebrew/opt/bison/bin/bison ]; then
    BISON_BIN=/opt/homebrew/opt/bison/bin/bison
elif [ -x /usr/local/opt/bison/bin/bison ]; then
    BISON_BIN=/usr/local/opt/bison/bin/bison
else
    echo "GNU Bison is required. Install it with: brew install bison" >&2
    exit 1
fi

mkdir -p "${WORKSPACE_ROOT}/dist" "${WORKSPACE_ROOT}/build"

if [ ! -f "${SOURCE_ARCHIVE}" ]; then
    echo "Missing Wine source archive. Run: make fetch-wine-source" >&2
    exit 1
fi

ACTUAL_SOURCE_SHA256="$(shasum -a 256 "${SOURCE_ARCHIVE}" | awk '{print $1}')"
if [ "${ACTUAL_SOURCE_SHA256}" != "${WINE_SOURCE_SHA256}" ]; then
    echo "Wine source archive SHA-256 mismatch; refusing to build." >&2
    exit 1
fi

PATCH_SHA256="$(shasum -a 256 "${DRIVER_PATCH}" | awk '{print $1}')"
SCRIPT_SHA256="$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')"
VERSIONS_SHA256="$(shasum -a 256 "${MACSW_VERSIONS_FILE}" | awk '{print $1}')"
CONFIG_LOADER_SHA256="$(shasum -a 256 "${WORKSPACE_ROOT}/scripts/lib/config.sh" | awk '{print $1}')"
BUILD_KEY="${WINE_VERSION}:${WINE_SOURCE_SHA256}:${PATCH_SHA256}:${SCRIPT_SHA256}:${VERSIONS_SHA256}:${CONFIG_LOADER_SHA256}"
if [ -f "${OUTPUT_FILE}" ] && [ -f "${STAMP_FILE}" ] &&
   [ "$(<"${STAMP_FILE}")" = "${BUILD_KEY}" ]; then
    echo "==> Patched winemac.so is up to date."
    exit 0
fi

STAGING_ROOT="$(mktemp -d "${WORKSPACE_ROOT}/build/.winemac.XXXXXX")"
trap 'rm -rf -- "${STAGING_ROOT}"' EXIT
SOURCE_DIR="${STAGING_ROOT}/source"
BUILD_DIR="${STAGING_ROOT}/build"
mkdir -p "${SOURCE_DIR}" "${BUILD_DIR}"
tar -xf "${SOURCE_ARCHIVE}" -C "${SOURCE_DIR}" --strip-components=1

git -C "${SOURCE_DIR}" init -q
git -C "${SOURCE_DIR}" apply --check "${DRIVER_PATCH}"
git -C "${SOURCE_DIR}" apply "${DRIVER_PATCH}"

export MACOSX_DEPLOYMENT_TARGET="${WINE_DRIVER_DEPLOYMENT_TARGET}"
pushd "${BUILD_DIR}" >/dev/null
"${SOURCE_DIR}/configure" \
    --build=x86_64-apple-darwin \
    --enable-archs=i386,x86_64 \
    --disable-tests \
    --disable-winebth_sys \
    --without-alsa \
    --without-capi \
    --with-coreaudio \
    --without-cups \
    --without-dbus \
    --without-ffmpeg \
    --without-fontconfig \
    --without-freetype \
    --without-gettext \
    --without-gettextpo \
    --without-gphoto \
    --without-gnutls \
    --without-gssapi \
    --without-gstreamer \
    --without-inotify \
    --without-krb5 \
    --without-netapi \
    --without-opencl \
    --without-opengl \
    --without-oss \
    --without-pcap \
    --without-pcsclite \
    --with-pthread \
    --without-pulse \
    --without-sane \
    --without-sdl \
    --without-udev \
    --without-usb \
    --without-v4l2 \
    --with-vulkan \
    --without-wayland \
    --without-x \
    CC="/usr/bin/clang -arch x86_64 -mmacosx-version-min=${WINE_DRIVER_DEPLOYMENT_TARGET}" \
    CXX="/usr/bin/clang++ -arch x86_64 -mmacosx-version-min=${WINE_DRIVER_DEPLOYMENT_TARGET}" \
    CFLAGS="-O2" \
    LDFLAGS="-arch x86_64 -mmacosx-version-min=${WINE_DRIVER_DEPLOYMENT_TARGET} -Wl,-rpath,@loader_path" \
    BISON="${BISON_BIN}" \
    ac_cv_lib_soname_vulkan=libvulkan.1.dylib
popd >/dev/null

MAKE_JOBS="${MAKE_JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || printf '4')}"
make -C "${BUILD_DIR}" -j"${MAKE_JOBS}" dlls/winemac.drv/winemac.so

mkdir -p "${OUTPUT_DIR}"
cp "${BUILD_DIR}/dlls/winemac.drv/winemac.so" "${OUTPUT_FILE}.new"
install_name_tool -id winemac.so "${OUTPUT_FILE}.new"
codesign --force --sign - "${OUTPUT_FILE}.new"
file "${OUTPUT_FILE}.new" | grep -q 'x86_64'
codesign --verify --verbose=2 "${OUTPUT_FILE}.new"
mv "${OUTPUT_FILE}.new" "${OUTPUT_FILE}"
printf '%s' "${BUILD_KEY}" > "${STAMP_FILE}"

echo "==> Patched Wine macOS driver built: ${OUTPUT_FILE}"
