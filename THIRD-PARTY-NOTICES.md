---
title: 第三方组件声明
status: active
last_updated: 2026-10-15
---

# 第三方组件声明

FastBudo 使用 7-Zip 26.04，版权所有 Igor Pavlov 及原始组件作者。

7-Zip 的主要代码适用 LGPL 2.1 或更新版本，部分代码适用 BSD 及 unRAR 附加限制；RAR 解压源码不得用于重新实现 RAR 压缩算法。完整许可见 [Vendor/7zip/LICENSE.txt](Vendor/7zip/LICENSE.txt)，其他版权和许可证保留在原始源码包中。

仓库包含未经修改的官方对应源码包 [7z2604-src.tar.xz](Vendor/7zip/7z2604-src.tar.xz)，其来源与 SHA-256 见 [manifest.json](Vendor/7zip/manifest.json)。使用 `bash scripts/build-engine.sh` 可重新构建格式库、命令行工具及独立桥接；桥接源码也在本仓库内。正式二进制分发时必须同时提供这些声明、对应源码和构建方法，并允许用户替换/重新链接 LGPL 组件，不只分发一个无声明安装包。

当前构建仅用于本地验证，尚未公开分发安装包。

测试样本来自 libarchive 3.8.1，许可及源文件版权头保存在 Tests/Fixtures/libarchive 中，来源和逐文件哈希见 Tests/Fixtures/manifest.json；这些样本不随应用运行资源打包。旧式 RAR 编号测试仅在临时目录派生样本并修正主头编号标志及 CRC。
