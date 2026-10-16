---
title: 本地 iCopy 功能分析与 FastBudo 剪贴板模块范围建议
status: active
last_updated: 2026-10-15
---

# 本地 iCopy 功能分析与实现范围建议

返回[文档索引](../README.md)。核心模块已集成。实际范围、运行与验证见[剪贴板使用说明](../guides/clipboard.md)。下文保留最初方案对照，最终实现以使用说明为准。

> 2026-10-16 更新：用户确认改为逐行拷贝/收藏/删除，取消自动粘贴与辅助功能授权入口。下表保留首版对照；当前行为以[使用说明](../guides/clipboard.md)为准。

## 1. 分析对象与证据边界

- 应用：`/Applications/iCopy.app`，标识 `cn.better365.iCopy`。
- 本地版本：1.3.4，构建 2026050102；Info.plist 声明最低 macOS 10.14，LSUIElement=true。
- 证据：应用 Info.plist、应用包内 `Contents/Resources/zh-Hans.lproj/Localizable.strings` 及静态界面资源名称。
- 未读取剪贴板历史数据库、附件、用户偏好值、账户或真实剪贴板内容。没有复制原版代码、界面素材或商标。
- 以下“资源确认”表示发行包包含对应功能文案，不能证明当前账户可用、具体默认值、实现算法或运行质量。尚未逐项实机操作 iCopy，不能宣称完全功能对等。
- AppCenter 等第三方 bundle 的存在不等于已经证实应用运行时上传数据。

## 2. 核心模块与交互对照

| 模块 | 本地证据及可确认作用 | 交互与未确认边界 | 建议实现范围 |
|---|---|---|---|
| 历史记录 | Clipboard、Clipboard History Limit、Storage Time Limit | 采集复制内容并再次使用；采样策略、去重规则未实测 | 完整：文本、常见富文本、图片、文件引用；去重、时间与来源展示 |
| 内容类型与预览 | Text、Rich text、Image、File、Folder、Mutil file、Text Preview | 按类型显示和预览；任意私有剪贴板格式未确认 | 常见类型完整；专有应用格式不承诺 |
| 搜索 | Search、Search Box、Default Focus | 搜索框筛选；是否搜索图片 OCR、文件正文未确认 | 文本内容、文件名和路径、快捷回复标题；不自动 OCR |
| 分组/分类 | Custom Group、New category、Category manage、Hover to Switch Group | 创建分组、切换分组；资源不能确认自由多标签模型 | 用户分组、类型筛选；一条一个自定义分组，暂不做多标签 |
| 收藏与置顶 | Collect、Cancel collect、Pin to Top、Unpin | 收藏便于复用，置顶改变排序；两者不是同一状态 | 独立收藏与置顶；清理规则可保留收藏/置顶 |
| 快捷粘贴 | Double Click/Enter、Number Shortcut、Paste as plain text/rich text | 双击或回车操作，数字快捷操作；当前具体快捷键未读取 | 回车/双击粘贴、方向键选择、前九项快捷操作、复制回退 |
| 文本转换 | Copy(remove line breaks)、remove line breaks and spaces | 复制或粘贴前转换文本 | 原样、纯文本、去换行；去全部空白作为明确选项 |
| 全局唤起 | Show/Hide Clipboard Panel、Shortcut Key、Quick Reply Panel Toggle | 独立唤起历史及快捷回复；实际绑定未读取 | 可配置唤起组合键、冲突提示；快捷回复共用面板 |
| 快捷回复 | Quick Reply、Add quick reply、Title、Content、Drag to sort | 手动维护可复用内容与分组 | 文本回复、标题、分组、编辑、删除、排序完整；图文混排简化 |
| 剪贴板堆栈 | Clipboard Stack、Add to Stack、Send data one by one、Reverse、Lock | 条目排队、逐条发送、反转、锁定不自动清除 | 简化：显式加入队列、逐条粘贴、反转；暂不模拟全部原版操作 |
| 持久化 | 资源说明 data.sqlite、reply.sqlite、tempFiles、icons | 历史和回复独立数据库、图片附件；未读取实际 schema | 自有 SQLite schema，内容内联，不读写 iCopy 数据库 |
| 隐私与黑名单 | 剪贴板监听黑名单、快捷键操作黑名单、Permissions | 分别排除采集及快捷键；直接输入要求辅助功能 | 两类排除、暂停采集、敏感类型过滤；权限缺失可复制后手动粘贴 |
| 清理策略 | 历史条数、存储时限、磁盘容量、Clear without favorite | 超限清理、按组清理、删除确认 | 数量/天数/容量限制，明确保留收藏，批量删除需确认 |
| 备份与导入导出 | iCloud、整体/配置/黑名单/快捷回复备份、Excel 批量导入导出 | 云备份及表格交换；一致性、加密和冲突处理未验证 | 本地自有格式导入导出；不做 iCloud、Excel、原版数据库迁移 |
| 外观与位置 | 横向/竖向、跟随光标、上次位置、多种主题、音效 | 可调整面板与交互 | 原生明暗外观、搜索列表与详情、记忆窗口位置；不逐一复刻主题/音效 |
| 系统设置 | Launch at Startup、Show Menu Bar Icon | 登录启动、状态栏入口 | 共用 FastBudo 状态栏；登录启动后续按需要支持 |

不能把同包中的 iShot/OCR、iRightMouse、FastZip 等推广文案算作 iCopy 自带功能。

## 3. 推荐技术栈

已加入现有 FastBudo，沿用 macOS / Swift 6 / SwiftUI + AppKit。本机已有项目兼容基线为 Apple Silicon / macOS 27；本任务不顺带声明兼容原版的 macOS 10.14。

| 层次 | 选型 | 原因 |
|---|---|---|
| 窗口与交互 | SwiftUI 列表、AppKit NSPanel | 复用当前原生项目；面板可控制激活、焦点和原应用恢复 |
| 剪贴板采集 | NSPasteboard.changeCount + 定时检查 | 系统能力，无第三方依赖；只在变化时读取，明确轮询可能漏掉极短间隔复制 |
| 数据 | 系统 SQLite3（内容内联） | 事务、索引、迁移与清理；不引入 ORM 或服务端 |
| 图片与富文本 | AppKit / UniformTypeIdentifiers | 规范化常见 PNG/TIFF、RTF/HTML，不承诺所有应用私有格式 |
| 全局快捷键 | 系统热键 API，优先 RegisterEventHotKey | 尽量避免全键盘监听；需实测本机 SDK 与快捷键冲突 |
| 自动粘贴 | AppKit 激活目标 + CGEvent Command-V | 需辅助功能授权；未授权或焦点不可信时只复制，不盲目投递 |
| 去重 | CryptoKit SHA-256 | 对规范化内容去重，不使用内容作为日志或文件名 |
| 设置 | UserDefaults | 与 FastBudo 偏好设置一致，仅存配置，不存剪贴板正文 |

不选 Electron/Tauri：当前没有 Web 界面可复用，会新增运行时和原生桥接。无需后端、账户、云服务或网络请求。SQLite 文件可独立导出，未来迁移平台时数据可迁移，窗口和权限代码需要重写。

## 4. 实现约定与主要差异

### 采集与存储

首次安装默认不采集，用户在剪贴板页开启后才观察后续变化，不把启动时已有剪贴板自动导入。默认建议：1000 条非收藏历史、30 天、总量 200 MiB，单条 20 MiB；实际值在设置页可见。收藏/置顶不被自动清理，若其占满容量则暂停接收并提示。

过滤系统/应用常见的 concealed、transient、自动生成等敏感剪贴板标记，并提供应用排除名单；不能保证识别所有密码或敏感文本。来源应用仅是采集时前台应用推断，不能作为可靠的安全归属。记录正文不进入日志。

首版数据为当前用户权限保护的本地数据库，不宣称端到端加密。文件记录保存引用而非完整文件副本，源文件删除或移动后可能失效。富文本转存和恢复需用合成样本验证；不加载 HTML 中远程资源或执行脚本。

### 面板与粘贴

菜单栏增加“剪贴板…”入口；全局唤起后焦点在搜索框，方向键选中，回车/双击执行，Escape 收起。来源、时间、类型、收藏和置顶状态均可见。分类、快捷回复与堆栈在同一面板中切换。

唤起前记录目标应用；粘贴前确认目标进程仍存在并激活，失败时保留内容在剪贴板供手动粘贴。不对密码输入框或失去焦点的未知窗口强行发送按键。不自动替用户授予辅助功能权限。

### 与原版的明确差异

核心本地工作流对齐，不承诺所有功能和体验一比一复刻。暂不做 iCloud、Excel、iCopy 数据库迁移、OCR、复杂图文快捷回复、全部主题与音效、自动跟随输入光标、完全磁盘访问、其他平台。全局快捷键默认值与实际权限行为需在实现时检测，不能承诺和原版相同。

## 5. 实现与验证

目录结构、构建启动、逐项验收和实际差异见[剪贴板使用说明](../guides/clipboard.md)，步骤见[实施计划](../superpowers/plans/2026-10-15-clipboard.md)。核心代码、自动测试和 Release 构建完成；未对 iCopy 逐项实机验收，不宣称完全对等。
