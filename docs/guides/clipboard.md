---
title: FastBudo 剪贴板使用与验证
status: active
last_updated: 2026-10-16
---

# FastBudo 剪贴板

返回[文档索引](../README.md)。[iCopy 分析](../analysis/2026-10-15-icopy-clipboard.md)记录功能证据、选型与范围；[实施计划](../superpowers/plans/2026-10-15-clipboard.md)记录开发步骤。

## 使用与完整实现的功能

打开 FastBudo，菜单栏 ⌘ →“剪贴板…”。默认关闭采集，点击“开启记录”只记录之后的新内容。设置 → 剪贴板配置数量、保留天数、容量、采集排除、快捷键排除及权限。

- 历史：文本、RTF/HTML、PNG/TIFF、文件引用，去重并持久化。
- 搜索：内容、文件名/路径、回复标题；类型及单分组筛选。
- 收藏与置顶：独立状态，右键或详情按钮操作；管理菜单维护分组，删除分组不删除内容。
- 快捷回复：标题、文本、分组、新增编辑删除及上下移动。
- 快捷键：默认 Control+Shift+V，可配置并提示注册冲突；Escape 收起，列表聚焦后方向键选择，回车/双击或 Command+1…9 粘贴。
- 输出：原样、纯文本、去换行、去全部空白；无纯文本表示的内容不能转换。
- 备份：管理菜单导入/导出自有 JSON。重复 UUID 跳过，校验失败回滚，成功导入仍应用清理策略。批量删除需要确认，不删除引用的原文件。

自动粘贴需要主动申请辅助功能权限；目标必须仍存活、成功激活并有可识别的非密码文本焦点，否则只复制，手动 Command+V。自绘或网页编辑器可能只能手动粘贴。

## 简化与不实现的部分

堆栈支持加入、反转、粘贴首条和手动移除。发送后仍保留条目，因为系统不确认目标是否接收；确认粘贴后再移除。分组是一条一个，不提供多标签。富文本保存表示但只预览已有纯文本，不执行 HTML 或访问远程资源。

不含 iCloud、Excel、iCopy 数据迁移、OCR、复杂图文回复、全部原版主题/音效、跟随输入光标、登录启动及其他平台，以保持本地原生工具规模。iCopy 仅做发行包静态分析，未逐项实机验收，不能宣称完全功能对等。

## 数据与限制

数据：`~/Library/Application Support/FastBudo/Clipboard/clipboard.sqlite`。SQLite 同事务保存元数据及内容，无独立附件。目录权限 700、数据库和导出文件 600，均未加密，不要把备份放入公开目录。

默认 1000 条普通历史、30 天、200 MiB 编码内容，在写入或手动清理时执行；SQLite 页和索引有额外开销。收藏/置顶/回复/堆栈免自动清理，保护内容占满容量会拒绝新记录。最多 10000 条，单条最多 20 MiB、200 个剪贴板项，图片另有像素限制。

每 0.5 秒检测变化，快速连续复制可能漏中间内容。敏感标记过滤与应用排除无法识别所有密码，来源是前台应用推断。文件只存本地 URL，原文件移动或删除会失效。常见格式可回放，应用私有格式不承诺兼容。

## 技术栈、代码与启动

沿用 Apple Silicon / macOS 27、Swift 6、SwiftUI/AppKit；系统 SQLite3 提供事务，CryptoKit 去重，ImageIO 校验图片，Carbon 注册快捷键，ApplicationServices 检查焦点并发送粘贴。不新增第三方库或网络服务。

```text
App/Clipboard/
  ClipboardItem.swift        内容模型、限制和输入校验
  ClipboardStore.swift       SQLite、去重、清理、分类、备份
  ClipboardCapture.swift     读写、敏感过滤、文本转换
  ClipboardController.swift  采集、生命周期、目标恢复和粘贴
  ClipboardHotKey.swift      系统快捷键与冲突处理
  ClipboardPanel.swift       搜索、列表、详情、回复和队列
  ClipboardSettings.swift    设置与授权入口
AppTests/ClipboardTests.swift 专用临时数据测试
```

AppDelegate 管理生命周期，FastBudoApp 提供设置和状态栏入口。需要 Xcode/Command Line Tools 和 Python 3（测试），无新增安装依赖；修改 project.yml 才需 XcodeGen。

```sh
bash scripts/build-engine.sh
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode
xcodebuild -scheme FastBudo -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
open .build/xcode/Build/Products/Release/FastBudo.app
```

本机安装位置 `~/Applications/FastBudo.app`，更新后待压缩任务完成，正常退出旧进程再打开。本地临时签名，无开发者公证。

## 验证记录（2026-10-16）

最新 xcodebuild test：30 项测试通过，参数化展开共执行 34 次，无失败/跳过；随后 Release 构建退出码 0。结果包 `.build/xcode/Logs/Test/Test-FastBudo-2026.10.16_00-19-34-+0800.xcresult`。

| 功能 | 自动验证 | 人工验证方式（尚未执行） |
|---|---|---|
| 历史、持久化、搜索 | 去重、重开数据库、字面搜索 | 复制合成文本并重开应用 |
| 图片、富文本、文件 | 合成 PNG/RTF、临时文件往返，超限与无效图片拒绝 | 测试文档检查粘贴保真 |
| 分类、收藏、置顶 | 删除分组保留记录，状态保留与清理豁免 | 切换筛选与排序 |
| 回复、堆栈 | 持久化及两种排序独立 | 新建编辑、反转、确认移除 |
| 清理、备份 | 容量回滚、备份往返与无效输入拒绝 | 修改限制、清理、导入导出 |
| 隐私 | 默认关闭、跳过已有内容、暂停、黑名单、敏感标记与自写过滤 | 用合成内容检查排除名单 |
| 快捷键、自动粘贴 | 编译通过，未做跨应用端到端验证 | TextEdit 测试文档中检查唤起、授权回退、目标退出与热键冲突 |
| 原有功能 | 同次执行已有 Swift 测试 | Finder 菜单与压缩本轮未人工复验 |

测试仅使用独立剪贴板和临时数据库，没有读取 iCopy 历史或覆盖真实系统剪贴板。
