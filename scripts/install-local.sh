#!/bin/bash
# 本机安装唯一入口：固定身份签名后原子替换 /Applications/FastBudo.app 并重启。
# 用 sign-local.sh 固定证书签名，保证 TCC 权限（屏幕录制/辅助功能等）跨重装保留；
# 绝不退回 ad-hoc 签名（ad-hoc 的 DR 锚定 CDHash，重编译即权限全重置）。
set -euo pipefail

repository=$(cd "$(dirname "$0")/.." && pwd)

# 定位最新构建产物目录：参数可显式指定，否则取最近的 .build/release-*。
build_dir="${1:-}"
if [[ -z "$build_dir" ]]; then
    build_dir=$(ls -1dt "$repository"/.build/release-* 2>/dev/null | head -n 1 || true)
fi
if [[ -z "$build_dir" || ! -d "$build_dir/Build/Products/Release/FastBudo.app" ]]; then
    echo '找不到 Release 构建产物。请先 xcodebuild build，或传入其 derivedDataPath（含 Build/Products/Release/FastBudo.app）。' >&2
    exit 1
fi
source_app="$build_dir/Build/Products/Release/FastBudo.app"

# 复制一份签名用副本（不动构建产物）。
stage="$repository/.build/install-local"
rm -rf "$stage"
mkdir -p "$stage"
ditto --norsrc --noextattr "$source_app" "$stage/FastBudo.app"

# 固定身份签名；sign-local.sh 缺身份会 exit 1 中止，不会退回 ad-hoc。
bash "$repository/scripts/sign-local.sh" "$stage/FastBudo.app"

# 退出正在运行的旧版本主进程（Finder 扩展由 Finder 托管，替换后系统会重载）。
pkill -f 'Contents/MacOS/FastBudo$' 2>/dev/null || true
sleep 1

# 时间戳备份旧版（禁止 rm -rf 覆盖重装），再装入新包。
timestamp=$(date +%s)
if [[ -d /Applications/FastBudo.app ]]; then
    mv /Applications/FastBudo.app "/Applications/FastBudo.app.bak.${timestamp}"
fi
mv "$stage/FastBudo.app" /Applications/FastBudo.app

# 重启。
open /Applications/FastBudo.app
echo "已安装并重启 FastBudo（备份：FastBudo.app.bak.${timestamp}）。"