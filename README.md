---
title: FastBudo
status: active
last_updated: 2026-10-15
---

# FastBudo

免费、本地运行的 macOS 压缩工具。Finder 快捷服务生成干净 ZIP；更多选项支持格式、密码和 Mac 属性设置。自有代码采用 MIT，第三方压缩引擎保留原许可。

当前验证环境为 Apple Silicon / macOS 27.0.1。首版不承诺其他系统或 Intel 兼容。

## 使用

把构建得到的 FastBudo.app 放到 `~/Applications`，首次打开一次。在 Finder 选中文件后，通过“服务”使用“FastBudo：快捷压缩 ZIP”或“FastBudo：更多压缩选项”。如果菜单未出现，在系统设置的键盘快捷键“服务”中启用对应项目；菜单位置由 macOS 决定。

应用窗口也可以直接选择文件或打开压缩包。双击关联由用户在 Finder 的“打开方式”中自行设置，应用不会修改默认关联。

默认过滤 .DS_Store 和已识别、有对应文件的 AppleDouble 元数据，不修改源文件，保留普通隐藏文件及普通 ._ 文件。保留 Mac 属性仅支持无密码 ZIP。解压结果写入独立目录，重名自动编号，不覆盖已有内容。

## 格式

| 格式 | 创建 | 解压 | 已验证组合 |
|---|---|---|---|
| ZIP | 是 | 是 | 普通 ZIP、AES-256、传统 ZipCrypto 解压、标准 .z01/.zip 分卷 |
| 7z | 是 | 是 | AES-256、加密文件名、.7z.001 连续分卷 |
| tar.gz | 是 | 是 | TAR + GZIP，内容及空目录 |
| RAR | 否 | 是 | RAR4/5、加密文件名、part1.rar 分卷、旧式 .rar/.r00 分卷 |

ZIP AES 不保证被系统自带解压器打开，ZIP 文件名仍可见；7z 密码模式默认加密文件名。分卷放在同一目录，ZIP 分卷从 .zip 打开，其他格式从首卷打开。不同条目使用不同密码的特殊归档未验证。

## 构建

需要 Xcode / Command Line Tools、Apple Silicon 和 Python 3（测试用）。无运行时 Homebrew 依赖。

```bash
bash scripts/build-engine.sh
xcodebuild -scheme FastBudo -configuration Release -derivedDataPath .build/xcode build
```

结果：`.build/xcode/Build/Products/Release/FastBudo.app`。引擎从仓库内固定版本源码构建；App 用 Xcode 标准资源复制阶段打包，不关闭构建脚本沙箱。

已提交 Xcode 工程可直接使用。修改 project.yml 时才需要本机已有的 XcodeGen，执行 `xcodegen generate` 后提交对应工程变化。首次构建前先运行引擎构建脚本，否则资源路径尚不存在。

## 验证

```bash
python3 -m unittest discover -s Tests/Bridge -v
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode
python3 scripts/test-low-space.py
```

最后一条仅创建、挂载并清理独立的 64 MiB 测试磁盘映像，不填满用户主盘。测试样本来自固定的 libarchive 3.8.1 发布包，来源、许可及哈希见 Tests/Fixtures/manifest.json。

## 首版边界

- 不浏览或编辑包内文件，不创建分卷，不创建 RAR，不递归解压。
- 拒绝符号链接、硬链接、设备条目和冲突路径；按保守的大小写及 Unicode 等价规则检测冲突。
- 展开超过 10 GiB、100,000 条目、1000 倍压缩比或大小未知时要求确认；确认不豁免路径安全。为控制内存，超过一百万条目或引擎输出超过 64 MiB 的归档仍可能被拒绝。
- 解压使用归档快照和独立暂存目录，需要额外空间；取消或失败时清理本任务暂存内容。异常退出后可在应用查看遗留 `.fastbudo-UUID` 目录，确认没有活跃任务后自行移到废纸篓。不要删除其他目录。
- 干净分享不是完整 Mac 备份。保留属性模式已经验证扩展属性与资源叉，但不承诺跨平台还原 Mac 专有信息。
- 当前为本地构建版本，没有开发者公证或自动更新；没有公开发布仓库或上传安装包。

## 文档与许可

- [文档索引](docs/README.md)
- [第三方声明](THIRD-PARTY-NOTICES.md)
- [MIT 许可证](LICENSE)
