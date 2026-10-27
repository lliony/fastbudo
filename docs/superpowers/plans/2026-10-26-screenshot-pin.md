---
title: 截图与贴图第一批实施计划
status: active
last_updated: 2026-10-26
related_spec: ../specs/2026-10-26-screenshot-pin-design.md
---

# 截图与贴图第一批实施计划

执行：subagent-driven-development，逐项实现并审查需求与质量；不自动提交或推送。

**目标：** 完成截图→标注→复制/保存/贴图闭环。
**架构：** ScreenshotController 管理截图进程、快捷键与窗口；ImageEditor 提供标注及导出；PinnedImage 管理浮窗变换。复用 ClipboardHotKey 与剪贴板数据库。
**技术：** Swift 6、SwiftUI、AppKit、ImageIO、系统 screencapture，无新增依赖。
**设计：** [第一批设计](../specs/2026-10-26-screenshot-pin-design.md)。

## 全局约束

原生实现，保持构建脚本沙箱。保存不覆盖；取消不改剪贴板；权限按需申请。UI/粘贴板主线程操作，图片尺寸与窗口数量有上限。不引入第二批功能。

## 任务一：标注与导出

文件：`App/Screenshot/ImageEditor.swift`、`AppTests/ImageEditorTests.swift`。
接口：`ImageEditor(image: NSImage, onPin: (NSImage) -> Void)`。

- [x] 实现独立像素坐标的标注模型，矩形/椭圆/箭头/画笔/文字/马赛克与撤销重做。
- [x] 画布和工具栏接入复制、保存、贴图；PNG 后台编码并使用 `.withoutOverwriting` 写入。
- [x] 测试撤销重做、导出像素和无覆盖；复核范围与质量。

## 任务二：截图、贴图与入口

文件：`App/Screenshot/ScreenshotController.swift`、`PinnedImage.swift`、`ScreenshotSettings.swift`；`AppDelegate.swift`、`FastBudoApp.swift`、剪贴板 Controller/Panel/HotKey 与 AppTests。
接口：`capture(_ mode: CaptureMode)`、`pin(_ image: NSImage)`、`paste()`、`togglePins()`。

- [x] 截图进程写专属临时目录；成功进入 ImageEditor，失败提示，取消/终止/超时清理。
- [x] 非激活图片浮窗提供变换、透明度和穿透；菜单恢复穿透；关闭释放持有者。
- [x] 快捷键读取 EventHotKeyID，只消费匹配事件；设置复用修饰键+按键模式。
- [x] 菜单接入三种截图和贴图管理；历史图片从数据库完整 payload 读取，不污染剪贴板。
- [x] 测试变换、快捷键匹配和资源边界；复核范围与质量。

## 任务三：验收与文档

- [x] `bash scripts/build-engine.sh`，`xcodegen generate`，App 测试与 Release 构建。
- [x] 同步 README、架构、未发布变更与文档索引。
- [x] 运行文档门禁、相对链接检查与 `git diff --check`。
- [x] 记录真实权限、多屏、Space、穿透和长期内存的验证边界，见[使用与验证](../../guides/screenshot-pin.md)。
