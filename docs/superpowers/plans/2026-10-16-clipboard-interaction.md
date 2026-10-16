---
title: 剪贴板基础设置与紧凑面板实施计划
status: active
last_updated: 2026-10-16
---

# 剪贴板基础设置与紧凑面板 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. 按用户选择顺序执行，不委派。

**Goal:** 可手输数值、逐行拷贝/收藏/删除，以及拷贝成功后按偏好关闭。

**Architecture:** 保留现有数据模型与 SQLite。Settings 维护数值草稿，Controller 校验及统一拷贝，Panel 负责紧凑列表与独立按钮。

**Tech Stack:** Swift 6、SwiftUI/AppKit、UserDefaults、现有系统 SQLite3。

**Spec:** 用户确认第二版预览（每行拷贝/收藏/删除，移除粘贴）为最终设计；[使用说明](../../guides/clipboard.md)为实际行为依据，返回[索引](../../README.md)。

## Global Constraints

- 当前兼容基线为 Apple Silicon / macOS 27；其他版本必须实测后再声明。
- 不新增依赖，不迁移数据库，不改变采集开关或清理豁免。
- 测试只使用独立 NSPasteboard 与临时目录。
- 本版明确取消自动粘贴，旧计划中的目标恢复与辅助功能授权不再适用。

## 任务与接口

- [x] 数值输入：`ClipboardController.validatedLimit(_:range:) -> Int?` 校验范围内整数；Settings 文件内 `ClipboardLimitField` 维护草稿，提交失败不改偏好。支持历史 100–10000 条、1–365 天、20–1024 MiB。
- [x] 交互偏好：`clipCopyOnClick`、`clipCloseAfterAction` 默认 true；`copy(_:)` 统一拷贝，成功按偏好隐藏，失败保留；移除旧 `use(_:paste:)`、目标跟踪和自动粘贴权限代码。
- [x] 面板：默认 620×560，最小 480×400；范围与筛选在顶部、每行独立拷贝/收藏/删除、底部管理与格式。详情和分组通过右键或管理菜单展开。回车/Command+1…9 均拷贝；行内管理按钮不触发内容点击。
- [x] 测试：`AppTests/ClipboardTests.swift` 先记录缺少新接口的失败；补齐数值边界、复制关闭/保留和失败不关闭测试。使用合成内容渲染明暗及窄窗口。
- [x] 完整测试、Release、实际 UI 核对、签名安装及提交。

## 验证命令

```sh
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode
xcodebuild -scheme FastBudo -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
python3 /Users/ly/.codex/skills/ai-project-standards/scripts/validate-project-standards.py --root .
git diff --check
```

## 验收

直接输入 350 条和 75 MiB 可保存；空白、10001 条、小数拒绝且旧值不变。成功拷贝在开关开启时关闭，关闭开关时保留；未知 UUID 失败不关闭。收藏和删除不写剪贴板。明暗与窄窗口按钮可读，长内容不挤压操作。实际权限和快捷键不做未经验证的成功声明。

交付记录：最终 34 项测试、44 次参数化执行通过；Release 与签名校验通过。已核对明暗与窄窗口合成渲染、实际数值错误提示、安装及重启，细节见使用说明。
