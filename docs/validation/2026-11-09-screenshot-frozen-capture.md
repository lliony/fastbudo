---
title: 区域/全屏截图冻结抓取右键菜单与浮窗验证
status: active
last_updated: 2026-11-09
---

# 区域/全屏截图可截取右键菜单与浮窗验证

实现说明见 [架构文档](../../ARCHITECTURE.md)，用户可感知变化见 [变更日志](../../CHANGELOG.md)，相关使用说明见 [截图与贴图](../guides/screenshot-pin.md)。

## 改动与行为

- 区域截图与全屏截图在触发瞬间先按显示器异步抓帧冻结（ScreenCaptureKit：`SCShareableContent` + `SCScreenshotManager` 一次性抓帧，读取窗口服务器、不激活本应用、不收起正在显示的右键菜单/浮窗），各屏冻结帧同时作为选区背景（所见即所得）与出图来源。
- 区域确认后从所选区域所在显示器的冻结帧按其缩放裁剪（`ScreenshotController.pixelRect` 换算像素区域，再 `cropping`）；全屏截图直接取所选显示器的冻结帧出图。
- 冻结帧不可用（选区跨屏、所在屏无帧、选区越界、或未授予屏幕录制权限）时回退系统 `screencapture -R`/`-D` 抓取，行为与改动前一致。
- 窗口截图保持系统窗口选取不变，不冻结。

## 单元验证

在 `AppTests/ScreenshotTests.swift` 新增以下测试，已经 `xcodebuild test` 实测通过（`TEST SUCCEEDED`，整体 166 tests / 21 suites 全绿）：

- `frozenCropMultipliesCaptureCoordinatesByScale`：冻结帧按 `scale` 与显示器原点偏移换算像素矩形；`scale = 0` 返回 `nil`。
- `frozenCropRejectsOutOfBoundsAndNegativeOrigin`：选区落在显示器左/上方（负坐标）或超出帧边界一律返回 `nil`，触发回退。
- `regionSelectorShowsWithFrozenBackground`：给选区选择器注入冻结帧后弹出遮罩并强制绘制，验证各屏冻结背景绘制路径不崩溃。

## 未测范围（须补）

- 核心行为（打开右键菜单/浮窗时发起区域或全屏截图能截入菜单）需真实系统交互验收：需屏幕录制权限，由 region/screen 走冻结路径实测，本环境仅完成重装与单元验证，未手工实测。
- 多显示器下各屏冻结帧一致性、选区跨屏时回退实际表现未实测。