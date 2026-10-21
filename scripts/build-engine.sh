#!/bin/bash
# 固定源码在本地构建；应用运行时不需要包管理器或网络。
set -euo pipefail
cd "$(dirname "$0")/.."
# Intel 发布可传 x86_64；默认保持本机 ARM 验证流程。
engine_arch=${1:-arm64}
case "$engine_arch" in
    arm64) make_arch=arm64 ;;
    x86_64) make_arch=x64 ;;
    *) echo '支持的架构：arm64、x86_64' >&2; exit 2 ;;
esac
source_archive=Vendor/7zip/7z2604-src.tar.xz
expected=9691944c0fe0d01bb49373a704fb983fd33bc98b1738695179dfbf99ac1734f6
actual=$(shasum -a 256 "$source_archive" | awk '{print $1}')
[[ "$actual" == "$expected" ]] || { echo '源码校验失败' >&2; exit 1; }
mkdir -p .build/upstream .build/engine
if [[ ! -f .build/upstream/CPP/7zip/Archive/IArchive.h ]]; then
    tar -xf "$source_archive" -C .build/upstream
fi
make -C .build/upstream/CPP/7zip/Bundles/Format7zF -f ../../cmpl_mac_${make_arch}.mak -j6 > .build/engine/build.log 2>&1
cp .build/upstream/CPP/7zip/Bundles/Format7zF/b/m_${make_arch}/7z.so .build/engine/
make -C .build/upstream/CPP/7zip/Bundles/Alone2 -f ../../cmpl_mac_${make_arch}.mak -j6 > .build/engine/cli-build.log 2>&1
cp .build/upstream/CPP/7zip/Bundles/Alone2/b/m_${make_arch}/7zz .build/engine/
clang++ -arch "$engine_arch" -std=c++17 -O2 -Wall -Wextra -I .build/upstream \
    Native/ArchiveBridge.cpp .build/upstream/CPP/Common/MyWindows.cpp \
    -framework CoreFoundation -o .build/engine/ArchiveBridge
