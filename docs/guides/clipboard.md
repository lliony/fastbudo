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
- 快捷键：默认 Control+Shift+V，可配置并提示注册冲突；Escape 收起，列表聚焦后方向键选择，回车或 Command+1…9 拷贝。
- 输出：原样、纯文本、去换行、去全部空白；无纯文本表示的内容不能转换。
- 备份：管理菜单导入/导出自有 JSON。重复 UUID 跳过，校验失败回滚，成功导入仍应用清理策略。批量删除需要确认，不删除引用的原文件。

每条记录右侧固定显示“拷贝、收藏、删除”，底部不提供粘贴按钮。单击条目默认拷贝，设置中可关闭以仅选中；回车及 Command+1…9 都只拷贝。成功后默认收起，可关闭“操作完成后关闭面板”；失败、收藏、删除都保持窗口。右键“查看详情”或“管理 → 查看所选条目”预览原内容和调整分组。需要输入到其他应用时自行 Command+V，本版不再发送粘贴按键或请求辅助功能权限。

基础设置的历史条数（100–10000）、天数（1–365）和容量（20–1024 MiB）均支持直接输入任意范围内整数，旁边保留步进按钮。回车或失焦保存，空白、非整数及超范围值显示错误并保留已保存值；不会因无效输入自动缩小清理上限。

## 简化与不实现的部分

堆栈支持加入、反转、逐条拷贝和手动移除。拷贝后仍保留条目，使用后自行移除。分组是一条一个，不提供多标签。富文本保存表示但只预览已有纯文本，不执行 HTML 或访问远程资源。

不含 iCloud、Excel、iCopy 数据迁移、OCR、复杂图文回复、全部原版主题/音效、跟随输入光标、登录启动及其他平台，以保持本地原生工具规模。iCopy 仅做发行包静态分析，未逐项实机验收，不能宣称完全功能对等。

## 数据与限制

数据：`~/Library/Application Support/FastBudo/Clipboard/clipboard.sqlite`。SQLite 同事务保存元数据及内容，无独立附件。目录权限 700、数据库和导出文件 600，均未加密，不要把备份放入公开目录。

默认 1000 条普通历史、30 天、200 MiB 编码内容，在写入或手动清理时执行；SQLite 页和索引有额外开销。收藏/置顶/回复/堆栈免自动清理，保护内容占满容量会拒绝新记录。最多 10000 条，单条最多 20 MiB、200 个剪贴板项，图片另有像素限制。

每 0.5 秒检测变化，快速连续复制可能漏中间内容。敏感标记过滤与应用排除无法识别所有密码，来源是前台应用推断。文件只存本地 URL，原文件移动或删除会失效。常见格式可回放，应用私有格式不承诺兼容。

## 技术栈、代码与启动

沿用 Apple Silicon / macOS 27、Swift 6、SwiftUI/AppKit；系统 SQLite3 提供事务，CryptoKit 去重，ImageIO 校验图片，Carbon 注册快捷键，原生剪贴板 API 完成拷贝。不新增第三方库或网络服务。

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

初版 xcodebuild test：30 项测试通过，参数化展开共执行 34 次，无失败/跳过；随后 Release 构建退出码 0。结果包 `.build/xcode/Logs/Test/Test-FastBudo-2026.10.16_00-19-34-+0800.xcresult`。

| 功能 | 自动验证 | 人工验证方式（尚未执行） |
|---|---|---|
| 历史、持久化、搜索 | 去重、重开数据库、字面搜索 | 复制合成文本并重开应用 |
| 图片、富文本、文件 | 合成 PNG/RTF、临时文件往返，超限与无效图片拒绝 | 测试文档检查粘贴保真 |
| 分类、收藏、置顶 | 删除分组保留记录，状态保留与清理豁免 | 切换筛选与排序 |
| 回复、堆栈 | 持久化及两种排序独立 | 新建编辑、反转、确认移除 |
| 清理、备份 | 容量回滚、备份往返与无效输入拒绝 | 修改限制、清理、导入导出 |
| 隐私 | 默认关闭、跳过已有内容、暂停、黑名单、敏感标记与自写过滤 | 用合成内容检查排除名单 |
| 快捷键 | 保留系统注册实现 | 唤起、热键冲突与键盘导航 |
| 原有功能 | 同次执行已有 Swift 测试 | Finder 菜单与压缩本轮未人工复验 |

测试仅使用独立剪贴板和临时数据库，没有读取 iCopy 历史或覆盖真实系统剪贴板。

## 紧凑界面更新（2026-10-16）

对应[改版计划](../superpowers/plans/2026-10-16-clipboard-interaction.md)。新增范围输入校验、拷贝成功后按偏好关闭、失败保留窗口的隔离测试；面板使用合成内容渲染 480/620 点宽度和明暗模式。与原版逐项自动粘贴的差异是用户本次明确选择，旧分析中的自动粘贴方案不再适用。

改版最终验证：34 项测试通过，参数化共执行 44 次，0 失败/跳过，Release 构建和安装包签名校验成功。结果包 `Test-FastBudo-2026.10.16_09-39-31-+0800.xcresult`。已在安装后的设置界面验证 10001 条输入提示范围错误且步进控件保存值仍为 1000，随后恢复输入框；已正常重启并核对逐行操作按钮。没有操作用户历史的拷贝/收藏/删除，相关拷贝关闭行为使用隔离自动测试验证。未复验全局快捷键冲突及 Finder 菜单。
