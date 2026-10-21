---
title: FastBudo
status: active
last_updated: 2026-10-17
---

# FastBudo

免费、本地运行的 macOS 工具，支持压缩、新建文件和剪贴板历史。Finder 右键子菜单直接选择 ZIP、7z 或 tar.gz；设置页管理 Mac 元数据偏好。自有代码采用 MIT，第三方压缩引擎保留原许可。

当前验证环境为 Apple Silicon / macOS 27.0.1。首版不承诺其他系统或 Intel 兼容。

## 使用

把构建得到的 FastBudo.app 放到 `~/Applications`，打开后点击菜单栏 ⌘ 图标 → 设置 → 通用 →“启用 Finder 右键扩展”，在系统设置中启用 FastBudo。选中文件后，使用 **FastBudo 压缩 → ZIP / 7z / TAR.GZ**：选中格式立即压缩，不弹出选项窗口，任务状态、取消和重试在菜单栏浮窗中查看。原生子菜单依赖 Finder Sync 扩展；未启用时仍可在右键“服务”中使用三个平铺格式入口，位置由 macOS 决定。需要开机自动启动时，打开设置 → 通用中的“开机自动启动”（默认关闭），登录后自动驻留菜单栏，不弹出窗口。

右键直接压缩不设密码，输出到原文件所在目录。元数据偏好在设置页管理。解压通过 Finder 的“打开方式 → FastBudo”发起；应用不会修改默认关联。旧版“更多压缩选项”窗口已移除，当前界面不提供加密压缩入口（引擎仍支持加密）。

在 Finder 文件夹空白处或选中文件/文件夹后右键，使用 **FastBudo 新建 → 文件夹 / TXT 文件 / MD 文件 / 自定义文件…**。新项目创建在当前目录（选择项的共同父目录），不进入选中的文件夹；跨目录搜索结果不显示新建。新建后在 Finder 原地编辑名称，不弹出 FastBudo 命名窗口；回车确认，Esc 保留默认名称。自动进入编辑需要在系统设置的辅助功能中允许 FastBudo，未授权时选中新项目后手动按回车。自定义项先创建“未命名.txt”，可在 Finder 修改名称及扩展名；已有同名项目不会覆盖，会自动编号并在 Finder 中选中新项目。设置页的“新建”可调整常用后缀（最多 12 项）。常用类型通过本机通知同步，扩展缓存最近的配置；修改时保持 FastBudo 运行并重新打开右键菜单。应用刚启动时若菜单尚未刷新，请关闭后再打开一次。

默认过滤 .DS_Store 和已识别、有对应文件的 AppleDouble 元数据，不修改源文件，保留普通隐藏文件及普通 ._ 文件。保留 Mac 属性仅支持无密码 ZIP。解压结果写入独立目录，重名自动编号，不覆盖已有内容。

菜单栏 ⌘ →“剪贴板…”支持历史、搜索、分类、收藏和快捷回复。默认关闭记录，Control+Shift+V 唤起；详见[剪贴板使用与验证](docs/guides/clipboard.md)。

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
- 安装包见 [GitHub Releases](https://github.com/lliony/fastbudo/releases)。当前仅验证 Apple Silicon / macOS 27，采用本地临时签名，没有开发者公证；系统可能拦截首次启动。在「设置 → 通用 → 版本更新」手动检查，已是最新版时显示提示，否则可点击「立即更新」下载、校验、安装并重启。更新使用同一发布的 SHA-256 清单校验安装包；无写入权限或正在处理归档时不会安装。旧应用保留在原应用旁的 `.fastbudo-update-*` 目录中；启动请求失败会尝试恢复，启动后崩溃需手动恢复旧版本。

## 文档与许可

- [文档索引](docs/README.md)
- [第三方声明](THIRD-PARTY-NOTICES.md)
- [MIT 许可证](LICENSE)
