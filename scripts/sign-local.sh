#!/bin/bash
# 本机安装固定复用钥匙串身份；缺少身份时拒绝退回 ad-hoc 签名。
set -euo pipefail

if [[ $# != 1 || ! -d "$1" ]]; then
    echo '用法：bash scripts/sign-local.sh <FastBudo.app>' >&2
    exit 1
fi
application=$(cd "$1" && pwd)
repository=$(cd "$(dirname "$0")/.." && pwd)
configuration="$HOME/Library/Application Support/FastBudo/signing-identity"
if [[ ! -f "$configuration" ]]; then
    echo '请先将固定证书的 SHA-1 写入 ~/Library/Application Support/FastBudo/signing-identity。' >&2
    exit 1
fi
identity=$(cat "$configuration")
if [[ ! "$identity" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    echo '本机签名身份配置无效，必须为证书的 40 位 SHA-1。' >&2
    exit 1
fi
if ! /usr/bin/security find-identity -v -p codesigning | /usr/bin/grep -Fq " $identity "; then
    echo '固定签名身份不可用：检查钥匙串是否解锁、证书是否过期及私钥是否存在。' >&2
    exit 1
fi
if [[ $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$application/Contents/Info.plist") != local.fastbudo.app ]]; then
    echo '拒绝签名：目标不是 FastBudo。' >&2
    exit 1
fi
# 由内向外签名，明确保留 Finder 扩展声明的沙箱权限。
for binary in 7zz 7z.so ArchiveBridge; do
    /usr/bin/codesign --force --sign "$identity" --timestamp=none "$application/Contents/Resources/$binary"
done
/usr/bin/codesign --force --sign "$identity" --timestamp=none \
    --entitlements "$repository/FinderExtension/FinderExtension.entitlements" \
    "$application/Contents/PlugIns/FastBudoFinder.appex"
/usr/bin/codesign --force --sign "$identity" --timestamp=none "$application"
/usr/bin/codesign --verify --deep --strict "$application"
echo '本机固定身份签名及完整性校验通过。'
