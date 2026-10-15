#!/bin/bash
# 固定源码在本地构建；应用运行时不需要包管理器或网络。
set -euo pipefail
cd "$(dirname "$0")/.."
source_archive=Vendor/7zip/7z2604-src.tar.xz
expected=9691944c0fe0d01bb49373a704fb983fd33bc98b1738695179dfbf99ac1734f6
actual=$(shasum -a 256 "$source_archive" | awk '{print $1}')
[[ "$actual" == "$expected" ]] || { echo '源码校验失败' >&2; exit 1; }
mkdir -p .build/upstream .build/engine
if [[ ! -f .build/upstream/CPP/7zip/Archive/IArchive.h ]]; then
    tar -xf "$source_archive" -C .build/upstream
fi
make -C .build/upstream/CPP/7zip/Bundles/Format7zF -f ../../cmpl_mac_arm64.mak -j6 > .build/engine/build.log 2>&1
cp .build/upstream/CPP/7zip/Bundles/Format7zF/b/m_arm64/7z.so .build/engine/
make -C .build/upstream/CPP/7zip/Bundles/Alone2 -f ../../cmpl_mac_arm64.mak -j6 > .build/engine/cli-build.log 2>&1
cp .build/upstream/CPP/7zip/Bundles/Alone2/b/m_arm64/7zz .build/engine/
clang++ -std=c++17 -O2 -Wall -Wextra -I .build/upstream \
    Native/ArchiveBridge.cpp .build/upstream/CPP/Common/MyWindows.cpp \
    -framework CoreFoundation -o .build/engine/ArchiveBridge
