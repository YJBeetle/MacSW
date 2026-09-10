#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# MacSW: Wine-crossover 自动化补丁与编译打包脚本 (Universal / macOS ARM64)
# ==============================================================================

WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES_DIR="${WORKSPACE_ROOT}/sources/wine-crossover"
PATCHES_DIR="${WORKSPACE_ROOT}/patches/wine-crossover"
BUILD_DIR="${WORKSPACE_ROOT}/build/wine-crossover"
DIST_DIR="${WORKSPACE_ROOT}/dist"
TARGET_ARCH="x86_64" # Always build x86_64 for Rosetta 2 execution of Windows x86/x64 binaries

DRY_RUN=false
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

for arg in "$@"; do
    case "${arg}" in
        --dry-run)
            DRY_RUN=true
            ;;
        -j*)
            JOBS="${arg#-j}"
            ;;
    esac
done

echo "======================================================================"
echo "          MacSW: Wine-crossover 构建流水线                            "
echo "  架构: ${TARGET_ARCH} | 线程数: ${JOBS} | 模式: $([ "${DRY_RUN}" = true ] && echo "DRY RUN" || echo "FULL BUILD")"
echo "======================================================================"

# 1. 确保 submodule 存在
if [ ! -f "${SOURCES_DIR}/configure" ]; then
    echo "==> [1/5] Submodule 未就绪，正在触发自动初始化..."
    "${WORKSPACE_ROOT}/scripts/init_submodules.sh"
else
    echo "==> [1/5] Submodule sources/wine-crossover 校验正常。"
fi

# 2. 应用 MacSW 专属定制补丁
echo "==> [2/5] 正在检查并应用 MacSW 定制补丁..."
cd "${SOURCES_DIR}"

for patch in "${PATCHES_DIR}"/*.patch; do
    [ -e "${patch}" ] || continue
    patch_name="$(basename "${patch}")"
    if git apply --check --reverse "${patch}" >/dev/null 2>&1; then
        echo "  [SKIP] 补丁已应用: ${patch_name}"
    elif git apply --check "${patch}" >/dev/null 2>&1; then
        echo "  [APPLY] 正在应用补丁: ${patch_name}..."
        git apply "${patch}"
    else
        echo "  [WARN] 补丁检查存在冲突，跳过或请手动排查: ${patch_name}"
    fi
done

if [ "${DRY_RUN}" = true ]; then
    echo "==> [DRY RUN] 补丁预检完成，退出。"
    exit 0
fi

# 3. 检查构建依赖
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo "/usr/local")"
export PATH="${BREW_PREFIX}/opt/llvm/bin:${BREW_PREFIX}/opt/bison/bin:${BREW_PREFIX}/opt/flex/bin:$PATH"

# 导出 Homebrew 关键开发库搜索路径（彻底解决 freetype / gnutls / molten-vk 找不到问题）
export PKG_CONFIG_PATH="${BREW_PREFIX}/lib/pkgconfig:${BREW_PREFIX}/opt/freetype/lib/pkgconfig:${BREW_PREFIX}/opt/gnutls/lib/pkgconfig:${BREW_PREFIX}/opt/molten-vk/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CPATH="${BREW_PREFIX}/include:${BREW_PREFIX}/opt/freetype/include/freetype2:${CPATH:-}"
export LIBRARY_PATH="${BREW_PREFIX}/lib:${LIBRARY_PATH:-}"

echo "==> [3/5] 检查构建工具链 (Brew 前缀: ${BREW_PREFIX})..."
REQUIRED_TOOLS=("clang" "make" "bison" "flex" "pkg-config")
MISSING_TOOLS=()
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "${tool}" >/dev/null 2>&1; then
        MISSING_TOOLS+=("${tool}")
    fi
done

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
    echo "==> [ERROR] 缺少必要工具: ${MISSING_TOOLS[*]}"
    echo "    请在 macOS 上通过 Homebrew 安装: brew install lld llvm bison flex pkg-config mingw-w64 molten-vk freetype gnutls"
    exit 1
fi

CLANG_BIN="$(command -v clang)"
CLANGXX_BIN="$(command -v clang++)"
if [ -x "${BREW_PREFIX}/opt/llvm/bin/clang" ]; then
    CLANG_BIN="${BREW_PREFIX}/opt/llvm/bin/clang"
    CLANGXX_BIN="${BREW_PREFIX}/opt/llvm/bin/clang++"
fi

# 4. 配置与编译 (Configure & Make)
echo "==> [4/5] 正在配置构建目录: ${BUILD_DIR}..."
mkdir -p "${BUILD_DIR}"
cd "${BUILD_DIR}"

if [ ! -f "Makefile" ]; then
    EXTRA_CFG=()
    if [ "$(uname -m)" != "x86_64" ]; then
        EXTRA_CFG+=(
            --host=x86_64-apple-darwin
            CC="${CLANG_BIN} -arch x86_64"
            CXX="${CLANGXX_BIN} -arch x86_64"
            CFLAGS="-O2 -pipe -arch x86_64"
        )
    else
        EXTRA_CFG+=(
            CC="${CLANG_BIN}"
            CXX="${CLANGXX_BIN}"
            CFLAGS="-O2 -pipe"
        )
    fi

    "${SOURCES_DIR}/configure" \
        --enable-win64 \
        --without-x \
        --without-oss \
        --with-metal \
        --with-coreaudio \
        --disable-tests \
        "${EXTRA_CFG[@]}"
fi

echo "==> 正在执行并行编译 (make -j${JOBS})..."
make -j"${JOBS}"

# 5. 打包输出
echo "==> [5/5] 正在安装至临时目录并打包发布产物..."
INSTALL_TEMP="${BUILD_DIR}/install_temp"
rm -rf "${INSTALL_TEMP}"
make install DESTDIR="${INSTALL_TEMP}"

mkdir -p "${DIST_DIR}"
PACKAGE_NAME="wine-crossover-macsw-${TARGET_ARCH}.tar.gz"
echo "==> 正在创建归档: ${DIST_DIR}/${PACKAGE_NAME}..."
tar -czf "${DIST_DIR}/${PACKAGE_NAME}" -C "${INSTALL_TEMP}/usr/local" .

echo "======================================================================"
echo "  [SUCCESS] 构建成功！"
echo "  产物路径: ${DIST_DIR}/${PACKAGE_NAME}"
echo "======================================================================"
