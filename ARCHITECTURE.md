---
title: FastBudo 架构
status: active
last_updated: 2026-10-21
---

# FastBudo 架构

本文描述当前主分支实现。开发约束见 [AGENTS.md](AGENTS.md)，使用与构建见 [README](README.md)，发布变化见 [变更日志](CHANGELOG.md)。设计、计划与验证统一从 [文档索引](docs/README.md) 进入；历史设计不代表现有行为。

## 系统边界

FastBudo 是本地 SwiftUI / AppKit macOS 应用，由主应用、Finder Sync 扩展和随包分发的压缩引擎组成。没有 Web 壳、后台服务或云同步。当前工程与验证基线为 Apple Silicon / macOS 27。

```mermaid
flowchart LR
  Finder[Finder 右键扩展] -->|专用粘贴板 + URL scheme| App[主应用]
  Services[系统服务 / 打开文件] --> App
  App --> Queue[归档任务队列]
  Queue --> Engine[7zz / ArchiveBridge + 7z.so]
  Engine --> Output[暂存目录 → 排他提交输出]
  Pasteboard[系统剪贴板] --> Controller[ClipboardController]
  Controller --> Store[本地 SQLite]
  Controller --> Panel[剪贴板浮窗]
```

## 模块地图

| 模块 | 责任与主要入口 |
|---|---|
| 应用生命周期 | [FastBudoApp.swift](App/FastBudoApp.swift)、[AppDelegate.swift](App/AppDelegate.swift)：菜单栏、设置、任务窗口及外部请求分发 |
| 版本更新 | [UpdateChecker.swift](App/UpdateChecker.swift)、[UpdateInstaller.swift](App/UpdateInstaller.swift)：正式版检查、发布包校验、同卷替换与重启 |
| 登录项 | [LoginItem.swift](App/LoginItem.swift)：通过 `SMAppService.mainApp` 管理，状态以系统为准 |
| Finder 入口 | [FinderSync.swift](FinderExtension/FinderSync.swift)、[FinderRequest.swift](Shared/FinderRequest.swift)：菜单快照、请求传递与校验 |
| 新建 | [NewItem.swift](App/NewItem.swift)、[FinderRename.swift](App/FinderRename.swift)、[NewItemTypes.swift](Shared/NewItemTypes.swift)：排他创建、原地重命名与常用后缀 |
| 归档调度 | [ArchiveModel.swift](App/ArchiveModel.swift)：串行任务、进度、取消、重试与展开确认 |
| 归档执行 | [ArchiveEngine.swift](App/ArchiveEngine.swift)、[ArchiveFiles.swift](App/ArchiveFiles.swift)：快照、子进程、文件复制及输出提交 |
| 原生桥接 | [ArchiveBridge.cpp](Native/ArchiveBridge.cpp)：结构化枚举、安全条目校验与解压 |
| 剪贴板协调 | [ClipboardController.swift](App/Clipboard/ClipboardController.swift)、[ClipboardCapture.swift](App/Clipboard/ClipboardCapture.swift)：采集、查询、复制与刷新 |
| 剪贴板数据 | [ClipboardStore.swift](App/Clipboard/ClipboardStore.swift)、[ClipboardItem.swift](App/Clipboard/ClipboardItem.swift)：SQLite、内容编码、备份及缩略图 |
| 剪贴板界面 | [ClipboardPanel.swift](App/Clipboard/ClipboardPanel.swift)、[ClipboardHotKey.swift](App/Clipboard/ClipboardHotKey.swift)：列表、详情与全局快捷键 |

## 生命周期与 Finder 请求

普通启动或再次点击应用图标打开设置；服务或文件触发时避免抢占设置窗口。关闭最后一个主窗口后切换为 accessory，移出 Dock，但菜单栏和剪贴板入口继续运行。

Finder 扩展处于独立沙箱进程，只构造菜单和请求，不执行压缩。菜单 tag 映射到扩展内部的请求快照。文件 URL 放入专用 `NSPasteboard`，`fastbudo://compress|create` 仅传递粘贴板名称与动作参数。主应用验证 scheme、host、参数唯一性及本地文件 URL；新建请求必须只有一个目标目录。系统“服务”经 [ServicesProvider.swift](App/ServicesProvider.swift) 和 [ServiceInput.swift](App/ServiceInput.swift) 进入归档流程。

常用新建后缀通过本机分布式通知同步，扩展独立缓存配置；不是共享数据库。选择项必须有共同父目录，跨目录搜索结果不猜测新建位置。创建任务在后台使用排他文件操作，遇重名自动编号，不覆盖已有内容。Finder 重命名仍在主线程进行有界 AX 遍历，确认唯一目标与前台 Finder 进程后触发回车；需要用户授予辅助功能权限。

## 归档数据流与安全边界

1. `ArchiveModel` 在主线程管理串行队列；`ArchiveEngine` 后台执行，锁保护子进程与取消状态。
2. 创建专属 `.fastbudo-UUID` 工作目录，归并输入路径并复制快照。复制按 1 MiB 分块，并逐块释放临时对象；当前仍是普通复制，没有 clone 或硬链接快照。
3. 创建归档调用随包 `7zz`；条目枚举和解压使用 `ArchiveBridge` 与 `7z.so`。tar.gz 使用中间 tar。分卷准备复用匹配计算，但仍需扫描并排序相邻目录内容。
4. 桥接验证条目类型、路径与资源预算，再写入暂存目录。人类可读的 `7zz` 列表不能充当路径安全边界；list 返回结构化条目，extract 成功仅返回 `{"ok":true}`。
5. 完成元数据与 quarantine 处理后，通过排他重命名提交输出；不覆盖输入或已有输出。失败、取消清理本任务工作目录，遗留路径记录到偏好设置供后续处理。

密码只经标准输入管道传递。子进程输出上限为 64 MiB，取消会终止子进程。展开大小、数量与压缩比超过阈值时要求确认，但确认不能绕过路径校验。结果 URL 历史最多保留 20 项，不影响磁盘文件。具体限制见 [README](README.md)。

## 剪贴板数据流与并发

`ClipboardController` 是主线程协调者。记录默认关闭；开启后每 0.5 秒检查 changeCount，timer 容差 0.1 秒。暂停时销毁 timer，恢复时跳过暂停期间的旧内容，快捷键保持独立。AppKit 粘贴板操作留在主线程，纯文本转换和数据库工作在后台执行。

采集过滤不支持的类型与敏感标记，并识别应用自身写入。允许文本、RTF、HTML、PNG、TIFF 和文件 URL，单条负载上限 20 MiB。新增内容复用编码及 SHA-256 哈希，以内容去重；历史按最近使用排序，手动顺序独立保存。

查询最多保留一个进行中的 reload 任务，并合并最新请求；generation 丢弃过期结果，不依赖 SQLite interrupt。面板隐藏时采集只持久化，显示时再加载。列表缓存筛选结果，批量快照只重建一次；紧凑行使用 Equatable 降低刷新，时间标签按分钟更新，详情按需读取，图片预览降采样。

复制流程为“后台取内容及转换 → 主线程写粘贴板 → 后台更新使用时间 → 局部调整顺序”。复制使旧快照失效，必要时重新查询，避免旧结果覆盖最近使用排序。默认 Control+Shift+V 唤起；操作是复制，不自动向其他应用粘贴。

## 持久化与备份

| 数据 | 存储及约束 |
|---|---|
| 应用偏好 | UserDefaults；登录项启用状态直接查询系统 |
| 剪贴板历史 | `~/Library/Application Support/FastBudo/Clipboard/clipboard.sqlite`，NSLock 串行保护一个 SQLite FULLMUTEX 连接 |
| SQLite schema 2 | `clips(id, meta, payload, hash, search, bytes)` 与 `groups(name)`；元数据和负载仍在同一表 |
| 搜索 | `instr(lower(search), lower(?))` 子串匹配，保留中文及 `%`、`_` 的字面语义；未使用 FTS |
| 删除 | 开启 SQLite `secure_delete`；单条删除不执行 VACUUM，空间整理留到手动清理。此设置不等于底层磁盘或系统备份的取证擦除 |
| 备份 | 保留 v1 JSON，流式读写；总大小 2 GiB、单值 64 MiB、最多 10,000 条记录和 1,000 个分类；日期限定 1970–9999 |

导入在一个事务中完成，失败回滚；导出使用权限 0600 的临时文件并原子替换。历史及备份没有应用层加密，不应将本地存储理解为加密保险箱。不读取 iCopy 私有数据库，不上传剪贴板。

## 版本更新

设置页手动触发检查，`UpdateChecker` 优先访问 GitHub Releases API；403/429 时读取官网 latest 跳转，只接受本仓库 HTTPS 正式版标签。按三段数字比较版本，检查完成后才展示结果弹框；从 API 的可选 `body` 字段读取发布说明，以可选择的纯文本展示。说明为空或官网备用来源未提供内容时提示用户查看发布页，不阻断版本检查。下载与安装由用户再次确认。

`UpdateInstaller` 在后台下载固定命名的 arm64 ZIP 和同一发布的 SHA-256 清单，复用 `ArchiveEngine` 的安全解压及 Mac 属性恢复；随后验证应用标识、版本、架构、最低系统版本与签名完整性。校验和依赖 GitHub HTTPS 发布渠道，临时签名完整性检查不等同于开发者身份认证或公证。

暂存目录位于应用旁，权限 0700；主线程确认没有正在执行的归档任务后，以同卷目录交换保留旧应用，再退出并通过辅助进程重启。取消和准备失败只清理本次暂存目录。恢复能力与备份位置见 [README](README.md)；更新不修改剪贴板数据库和用户归档输出。

## 工程与验证边界

[project.yml](project.yml) 是工程配置源，包含主应用、Finder 扩展及 App 测试 target。引擎由 [build-engine.sh](scripts/build-engine.sh) 校验仓库内固定源码包后构建，资源随应用分发，不依赖运行时 Homebrew。修改配置后生成并提交 Xcode 工程，保持脚本沙箱启用。

验证命令见 [AGENTS.md](AGENTS.md)。Bridge 测试覆盖原生桥接与归档边界，App 测试覆盖 Swift 业务逻辑，Performance 测试提供独立进程内存回归检查；真实 Finder 权限、视图交互和安装包仍需人工验证。

两批优化结果见 [性能验证记录](docs/validation/2026-10-21-performance.md)。APFS clone、SQLite 拆表及 AX 后台迁移仍是条件方案，未接入生产流程；合成探针不能证明常驻内存、长期无泄漏或实际滚动帧率。网络卷与 Intel / macOS 26 不在本轮实测范围内。
