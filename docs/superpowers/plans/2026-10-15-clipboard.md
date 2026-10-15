---
title: FastBudo 剪贴板模块实施计划
status: active
last_updated: 2026-10-15
---

# FastBudo 剪贴板模块实施计划

按 executing-plans 顺序实施，不委派子代理。

目标：在已有 FastBudo 内提供本地剪贴板历史、搜索、分类、收藏/置顶、快捷回复、队列、快捷唤起与授权后的粘贴。

依据：[本地 iCopy 分析与范围建议](../../analysis/2026-10-15-icopy-clipboard.md)。用户已选择加入 FastBudo。SwiftUI/AppKit + 系统 SQLite3，不新增网络服务或第三方依赖。继续使用既有 macOS/Apple Silicon 基线。

实现调整：SQLite 同一事务保存元数据与原始表示，省去独立附件目录；容量设置按已编码内容估算，SQLite 页和索引有额外开销。原版功能证据仍仅为本地发行包资源，不夸大实机验证。

## 顺序任务

- [x] 1. 数据与存储：ClipboardItem、ClipboardStore；先测去重、保留状态、搜索、事务、清理及备份往返，再实现。
- [x] 2. 采集：ClipboardCapture；独立 NSPasteboard 测试文本/图片/文件、敏感标记、大小上限及写回，开启时不采集既有内容。
- [x] 3. 控制器与系统接入：后台串行数据库访问、暂停/黑名单、系统热键注册、目标焦点检查、无权限复制回退。
- [x] 4. 界面：剪贴板面板、分类和回复编辑、堆栈、设置；加入状态栏及 AppDelegate 生命周期，保留现有压缩/新建行为。
- [x] 5. 交付：测试、Release 构建、签名安装、运行说明、差异与实测边界。真实全局剪贴板、辅助功能、目标应用粘贴仅在可控合成数据环境验证。

## 文件职责与验证

`App/Clipboard/ClipboardItem.swift` 定义记录和表示；`ClipboardStore.swift` 管理 SQLite 事务、查询、清理和备份；`ClipboardCapture.swift` 负责剪贴板输入边界；`ClipboardController.swift` 负责状态与生命周期；`ClipboardHotKey.swift` 管理快捷键；`ClipboardPanel.swift` 和 `ClipboardSettings.swift` 管理界面。

`AppTests/ClipboardTests.swift` 使用临时数据库与独立剪贴板，不消费真实用户历史。运行现有 xcodebuild test/build；读测试报告区分自动验证与未完成的 UI 验收。每次内容变更后执行 git diff --check；文档变更后执行项目治理门禁。

交付及人工验收边界见[使用说明](../../guides/clipboard.md)。队列粘贴后保留，由用户确认移除。
