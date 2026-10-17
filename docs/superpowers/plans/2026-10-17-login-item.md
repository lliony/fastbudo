---
title: 开机自动启动实施计划
status: active
last_updated: 2026-10-17
related_spec: ../specs/2026-10-15-fastbudo-design.md
---

# 开机自动启动 Implementation Plan

**Goal:** 设置页「通用 → 本机运行」提供「开机自动启动」开关，登录 macOS 后 FastBudo 自动静默驻留菜单栏，默认关闭。

**Architecture:** 主应用未沙盒、本地临时签名，直接以 `SMAppService.mainApp` 注册主应用登录项，不引入 helper bundle 或 LaunchAgent。状态以系统为准（`SMAppService.mainApp.status`），不存本地偏好，与「系统设置 → 登录项」中的用户改动保持一致。

**Tech Stack:** Swift 6、ServiceManagement；不新增依赖。

**Spec:** [FastBudo 首版设计](../specs/2026-10-15-fastbudo-design.md)。返回[文档索引](../../README.md)。

## Global Constraints

- 默认关闭，用户手动开启；不自动改变系统配置（项目规则「不自动改变系统打开关联」）。
- 登录启动不弹出设置窗：沿用 `NSApplication.launchIsDefaultUserInfoKey` 现有行为，login item 冷启动时仅驻留菜单栏，不为此新增代码。
- SMAppService 是系统调用，不包单元测试；系统层行为以真机实测为准。
- 注册失败时开关回弹并 alert；`.requiresApproval` 状态给「系统设置」引导，不阻断。

## 文件与职责

| 文件 | 动作与职责 |
|---|---|
| `App/LoginItem.swift` | 新建；注册/注销/状态查询薄封装 |
| `App/FastBudoApp.swift` | PreferencesView「本机运行」增加开关、待批准引导与失败 alert |
| `FastBudo.xcodeproj/project.pbxproj` | 新文件入编，XcodeGen 重生成 |
| `.gitignore` | 忽略 `.worktrees/` |
| `docs/validation/2026-10-17-login-item.md` | 新建；实测记录与手动验证步骤 |
| `docs/README.md` | 索引登记 |
| `README.md` | 使用说明补一句 |

## 任务一：实现开关与状态同步

- [x] 新建 `LoginItem` 封装（status / setEnabled / openSystemSettings）。本 SDK 中 `unregister()` 为 throwing 签名，与旧文档的回调式不同，按探针编译结果适配。
- [x] 设置页加 `Toggle("开机自动启动")`，状态并入 `refreshEnabledStates()`；失败回弹 + alert；`.requiresApproval` 显示系统设置引导。
- [x] XcodeGen 重生成，工程 diff 仅含新文件（4 行）。

## 任务二：验证

- [x] `xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64'` 通过，既有测试无回归。
- [x] `python3 -m unittest discover -s Tests/Bridge -v` 18 项通过。
- [x] Release 构建 + 本地临时签名；探针程序实测 register/unregister/status 全链路（详见验证记录）。
- [x] 治理门禁 `validate-project-standards.py` 通过。

## 交付记录

实现于 worktree 分支 `feat/login-item`，验证完成后以快进方式合回 main。命令行无辅助功能权限，真实应用 UI 点击与注销登录实测列入验证记录的手动步骤，由用户执行。
