#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WINE_VERSION="11.16"
SOURCE_ARCHIVE="${WORKSPACE_ROOT}/dist/wine-${WINE_VERSION}.tar.xz"
SOURCE_URL="https://dl.winehq.org/wine/source/11.x/wine-${WINE_VERSION}.tar.xz"
SOURCE_SHA256="c66e2090343dcd727f7f7fd2f87ee0bfb0b118790c1d745ab7b8a4c3a4197f2f"
DRIVER_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0002-winemac-metal-layer-clipping.patch"
OUTPUT_DIR="${WORKSPACE_ROOT}/dist/winemac-${WINE_VERSION}"
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
    echo "==> Downloading Wine ${WINE_VERSION} source..."
    curl -fL --retry 3 "${SOURCE_URL}" -o "${SOURCE_ARCHIVE}.download"
    mv "${SOURCE_ARCHIVE}.download" "${SOURCE_ARCHIVE}"
fi

ACTUAL_SOURCE_SHA256="$(shasum -a 256 "${SOURCE_ARCHIVE}" | awk '{print $1}')"
if [ "${ACTUAL_SOURCE_SHA256}" != "${SOURCE_SHA256}" ]; then
    echo "Wine source archive SHA-256 mismatch; refusing to build." >&2
    exit 1
fi

PATCH_SHA256="$(shasum -a 256 "${DRIVER_PATCH}" | awk '{print $1}')"
SCRIPT_SHA256="$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')"
BUILD_KEY="${WINE_VERSION}:${SOURCE_SHA256}:${PATCH_SHA256}:${SCRIPT_SHA256}"
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

export MACOSX_DEPLOYMENT_TARGET=10.15
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
    CC="/usr/bin/clang -arch x86_64 -mmacosx-version-min=10.15" \
    CXX="/usr/bin/clang++ -arch x86_64 -mmacosx-version-min=10.15" \
    CFLAGS="-O2" \
    LDFLAGS="-arch x86_64 -mmacosx-version-min=10.15 -Wl,-rpath,@loader_path" \
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
