#!/usr/bin/env bash
set -euo pipefail

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${WORKSPACE_ROOT}/scripts/lib/config.sh"
SOURCE_ARCHIVE="${WORKSPACE_ROOT}/dist/${WINE_SOURCE_ASSET}"
DRIVER_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0002-winemac-metal-layer-clipping.patch"
INPUT_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0003-win32u-no-capture-resend.patch"
OPENGL_PATCH="${WORKSPACE_ROOT}/patches/wine-crossover/0004-winemac-preserve-front-buffer-flush.patch"
OUTPUT_DIR="${WORKSPACE_ROOT}/dist/${WINEMAC_OUTPUT_NAME}"
WINEMAC_OUTPUT="${OUTPUT_DIR}/winemac.so"
WIN32U_OUTPUT="${OUTPUT_DIR}/win32u.so"
STAMP_FILE="${OUTPUT_DIR}/build-key"

if [ -x /opt/homebrew/opt/bison/bin/bison ]; then
    BISON_BIN=/opt/homebrew/opt/bison/bin/bison
elif [ -x /usr/local/opt/bison/bin/bison ]; then
    BISON_BIN=/usr/local/opt/bison/bin/bison
else
    echo "GNU Bison is required. Install it with: brew install bison" >&2
    exit 1
fi

if [ -f /opt/homebrew/opt/freetype/include/freetype2/ft2build.h ]; then
    FREETYPE_INCLUDE=/opt/homebrew/opt/freetype/include/freetype2
elif [ -f /usr/local/opt/freetype/include/freetype2/ft2build.h ]; then
    FREETYPE_INCLUDE=/usr/local/opt/freetype/include/freetype2
else
    echo "FreeType headers are required to build win32u.so. Install them with: brew install freetype" >&2
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

DRIVER_PATCH_SHA256="$(shasum -a 256 "${DRIVER_PATCH}" | awk '{print $1}')"
INPUT_PATCH_SHA256="$(shasum -a 256 "${INPUT_PATCH}" | awk '{print $1}')"
OPENGL_PATCH_SHA256="$(shasum -a 256 "${OPENGL_PATCH}" | awk '{print $1}')"
SCRIPT_SHA256="$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')"
BUILD_KEY="${WINE_VERSION}:${WINE_SOURCE_SHA256}:${WINE_DRIVER_DEPLOYMENT_TARGET}:${DRIVER_PATCH_SHA256}:${INPUT_PATCH_SHA256}:${OPENGL_PATCH_SHA256}:${SCRIPT_SHA256}"
if [ -f "${WINEMAC_OUTPUT}" ] && [ -f "${WIN32U_OUTPUT}" ] && [ -f "${STAMP_FILE}" ] &&
   [ "$(<"${STAMP_FILE}")" = "${BUILD_KEY}" ]; then
    echo "==> Patched Wine modules are up to date."
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
git -C "${SOURCE_DIR}" apply --check "${INPUT_PATCH}"
git -C "${SOURCE_DIR}" apply "${INPUT_PATCH}"
git -C "${SOURCE_DIR}" apply --check "${OPENGL_PATCH}"
git -C "${SOURCE_DIR}" apply "${OPENGL_PATCH}"

export MACOSX_DEPLOYMENT_TARGET="${WINE_DRIVER_DEPLOYMENT_TARGET}"
pushd "${BUILD_DIR}" >/dev/null
FREETYPE_CFLAGS="-I${FREETYPE_INCLUDE}" \
FREETYPE_LIBS=" " \
ac_cv_lib_soname_freetype=libfreetype.6.dylib \
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
    --with-freetype \
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
make -C "${BUILD_DIR}" -j"${MAKE_JOBS}" \
    dlls/winemac.drv/winemac.so \
    dlls/win32u/win32u.so

mkdir -p "${OUTPUT_DIR}"
cp "${BUILD_DIR}/dlls/winemac.drv/winemac.so" "${WINEMAC_OUTPUT}.new"
cp "${BUILD_DIR}/dlls/win32u/win32u.so" "${WIN32U_OUTPUT}.new"
install_name_tool -id winemac.so "${WINEMAC_OUTPUT}.new"
install_name_tool -id win32u.so "${WIN32U_OUTPUT}.new"
install_name_tool -add_rpath '@loader_path/../../' "${WIN32U_OUTPUT}.new"
for MODULE in "${WINEMAC_OUTPUT}.new" "${WIN32U_OUTPUT}.new"; do
    codesign --force --sign - "${MODULE}"
    file "${MODULE}" | grep -q 'x86_64'
    codesign --verify --verbose=2 "${MODULE}"
done
unset MODULE
mv "${WINEMAC_OUTPUT}.new" "${WINEMAC_OUTPUT}"
mv "${WIN32U_OUTPUT}.new" "${WIN32U_OUTPUT}"
printf '%s' "${BUILD_KEY}" > "${STAMP_FILE}"

echo "==> Patched Wine modules built: ${WINEMAC_OUTPUT}, ${WIN32U_OUTPUT}"
