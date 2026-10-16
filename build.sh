#!/bin/bash
set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Dropbear + Zig 纯静态交叉编译工具${NC}"
echo -e "${GREEN}========================================${NC}"

# 1. 检查或自动下载 Zig 工具链
ZIG_VER="0.13.0"
if ! command -v zig &> /dev/null; then
    echo -e "${YELLOW}未检测到 zig，正在下载轻量级 Zig ${ZIG_VER} 工具链...${NC}"
    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        ZIG_ARCH="x86_64"
    elif [ "$ARCH" = "aarch64" ]; then
        ZIG_ARCH="aarch64"
    else
        ZIG_ARCH="x86_64"
    fi
    
    wget -q "https://ziglang.org/download/${ZIG_VER}/zig-linux-${ZIG_ARCH}-${ZIG_VER}.tar.xz"
    tar xf "zig-linux-${ZIG_ARCH}-${ZIG_VER}.tar.xz"
    export PATH="$(pwd)/zig-linux-${ZIG_ARCH}-${ZIG_VER}:$PATH"
    rm "zig-linux-${ZIG_ARCH}-${ZIG_VER}.tar.xz"
fi

echo -e "${GREEN}使用 Zig 版本: $(zig version)${NC}"

# 2. 获取 Dropbear 最新版本号（精确匹配带小数的版本号，如 2026.94）
DROPBEAR_VERSION=$(curl -s https://api.github.com/repos/mkj/dropbear/releases/latest | grep -oP '"tag_name":\s*"DROPBEAR_\K[0-9.]+' || true)
[ -z "$DROPBEAR_VERSION" ] && DROPBEAR_VERSION="2026.94"
echo -e "${GREEN}Dropbear 目标版本: ${DROPBEAR_VERSION}${NC}"

# 3. 下载并解压源码（优先使用 Dropbear 官方及镜像 Tarball）
if [ ! -d "dropbear-src" ]; then
    echo -e "${YELLOW}正在下载 Dropbear 源码...${NC}"
    mkdir -p dropbear-src
    
    DOWNLOAD_SUCCESS=0
    
    # 尝试源 1: 官方 UCC 主站
    if wget -q "https://matt.ucc.asn.au/dropbear/releases/dropbear-${DROPBEAR_VERSION}.tar.bz2" -O dropbear.tar.bz2; then
        tar xjf dropbear.tar.bz2 --strip-components=1 -C dropbear-src
        rm dropbear.tar.bz2
        DOWNLOAD_SUCCESS=1
    # 尝试源 2: 官方 Dropbear 镜像站
    elif wget -q "https://dropbear.nl/mirror/releases/dropbear-${DROPBEAR_VERSION}.tar.bz2" -O dropbear.tar.bz2; then
        tar xjf dropbear.tar.bz2 --strip-components=1 -C dropbear-src
        rm dropbear.tar.bz2
        DOWNLOAD_SUCCESS=1
    # 尝试源 3: GitHub 源码 Tag 打包
    elif wget -q "https://github.com/mkj/dropbear/archive/refs/tags/DROPBEAR_${DROPBEAR_VERSION}.tar.gz" -O dropbear.tar.gz; then
        tar xzf dropbear.tar.gz --strip-components=1 -C dropbear-src
        rm dropbear.tar.gz
        DOWNLOAD_SUCCESS=1
    fi

    if [ $DOWNLOAD_SUCCESS -eq 0 ]; then
        echo -e "${RED}❌ 错误：无法从任何已知源下载 Dropbear ${DROPBEAR_VERSION} 源码！${NC}"
        exit 1
    fi
fi

OUTPUT_DIR="output"
mkdir -p "${OUTPUT_DIR}"

# 4. 单架构编译函数
build_target() {
    local target_arch=$1      # 架构名称，如 amd64, arm64, armv7
    local zig_target=$2       # Zig 目标三元组，如 x86_64-linux-musl
    local host_gnu=$3         # configure --host
    
    echo -e "\n${YELLOW}========================================${NC}"
    echo -e "${YELLOW}🚀 正在使用 Zig 编译 ${target_arch} (${zig_target})...${NC}"
    echo -e "${YELLOW}========================================${NC}"

    BUILD_DIR="build-${target_arch}"
    rm -rf "${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"
    
    # 拷贝一份源码专门用于该架构构建
    cp -r dropbear-src/* "${BUILD_DIR}/"
    cd "${BUILD_DIR}"

    # 设置 Zig C 编译器与静态编译标志
    export CC="zig cc -target ${zig_target}"
    export AR="zig ar"
    export RANLIB="zig ranlib"

    # 配置 configure 参数（禁用外部库，实现纯静态单文件依赖）
    ./configure \
        --host="${host_gnu}" \
        --disable-zlib \
        --disable-pam \
        --disable-syslog

    # 执行构建（多链合一模式 MULTILINK=1）
    make PROGRAMS="dropbear dbclient dropbearkey dropbearconvert scp" \
         MULTILINK=1 \
         STATIC=1 \
         EXTRA_CFLAGS="-static -O3" \
         -j$(nproc)

    # 打包输出
    DIST_DIR="dropbear-static-${target_arch}"
    mkdir -p "${DIST_DIR}"
    
    cp dropbearkey dropbearconvert scp "${DIST_DIR}/"
    cp dropbear "${DIST_DIR}/dropbear"
    ln -sf dropbear "${DIST_DIR}/dbclient"

    TAR_NAME="dropbear-${DROPBEAR_VERSION}-static-${target_arch}.tar.gz"
    tar -czf "../../${OUTPUT_DIR}/${TAR_NAME}" -C "${DIST_DIR}" .
    
    cd ..
    rm -rf "${BUILD_DIR}"
    echo -e "${GREEN}✅ ${target_arch} 构建成功！文件: ${OUTPUT_DIR}/${TAR_NAME}${NC}"
}

# 5. 根据参数构建对应架构或全量构建
ARCH_ARG=$1

case "$ARCH_ARG" in
    amd64)
        build_target "amd64" "x86_64-linux-musl" "x86_64-linux"
        ;;
    arm64)
        build_target "arm64" "aarch64-linux-musl" "aarch64-linux"
        ;;
    armv7)
        build_target "armv7" "arm-linux-musleabihf" "arm-linux"
        ;;
    *)
        echo -e "${YELLOW}未指定特定架构，一次性编译所有架构 (amd64, arm64, armv7)...${NC}"
        build_target "amd64" "x86_64-linux-musl" "x86_64-linux"
        build_target "arm64" "aarch64-linux-musl" "aarch64-linux"
        build_target "armv7" "arm-linux-musleabihf" "arm-linux"
        ;;
esac

echo -e "\n${GREEN}🎉 所有编译任务完成！输出目录：${OUTPUT_DIR}/${NC}"