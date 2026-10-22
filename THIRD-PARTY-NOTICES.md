---
title: 第三方组件声明
status: active
last_updated: 2026-10-22
---

# 第三方组件声明

FastBudo 使用 7-Zip 26.04，版权所有 Igor Pavlov 及原始组件作者。

7-Zip 的主要代码适用 LGPL 2.1 或更新版本，部分代码适用 BSD 及 unRAR 附加限制；RAR 解压源码不得用于重新实现 RAR 压缩算法。许可摘要及 BSD/unRAR 条款见 [Vendor/7zip/LICENSE.txt](Vendor/7zip/LICENSE.txt)，LGPL 2.1 完整正文见 [Vendor/7zip/COPYING.txt](Vendor/7zip/COPYING.txt)，其他版权和许可证保留在原始源码包中。

仓库包含未经修改的官方对应源码包 [7z2604-src.tar.xz](Vendor/7zip/7z2604-src.tar.xz)，其来源与 SHA-256 见 [manifest.json](Vendor/7zip/manifest.json)。使用 `bash scripts/build-engine.sh` 可重新构建格式库、命令行工具及独立桥接；桥接源码也在本仓库内。正式二进制分发时必须同时提供这些声明、对应源码和构建方法，并允许用户替换/重新链接 LGPL 组件，不只分发一个无声明安装包。

修复后的安装包在 `FastBudo.app/Contents/Resources` 内随附自有代码的 `LICENSE`、本声明、7-Zip 的 `LICENSE.txt` 及 LGPL 完整正文 `COPYING.txt`。历史安装包是否已替换，以对应 Release 附件为准。

对应源码及构建脚本在 [GitHub Releases](https://github.com/lliony/fastbudo/releases) 的同版本 `FastBudo-<版本>-source.tar.gz` 中提供，包含固定的 7-Zip 原始源码包。应用版本见 `Contents/Info.plist`。源码中的 `bash scripts/build-engine.sh arm64` 或 `bash scripts/build-engine.sh x86_64` 生成 `7z.so`、`7zz` 和 `ArchiveBridge`。

用户可以退出应用后，在应用副本的 `Contents/Resources` 中替换同架构的上述组件，或使用源码重新构建应用。替换后可执行 `codesign --force --deep --sign - FastBudo.app` 自行临时签名，再执行 `codesign --verify --deep --strict FastBudo.app` 检查。自行签名不等于 Apple 公证；首次运行仍可能需要系统安全确认。允许为调试 LGPL 组件的修改而进行必要的逆向工程。

测试样本来自 libarchive 3.8.1，许可及源文件版权头保存在 Tests/Fixtures/libarchive 中，来源和逐文件哈希见 Tests/Fixtures/manifest.json；这些样本不随应用运行资源打包。旧式 RAR 编号测试仅在临时目录派生样本并修正主头编号标志及 CRC。
