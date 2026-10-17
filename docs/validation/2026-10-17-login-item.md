---
title: 开机自动启动验证记录
status: active
last_updated: 2026-10-17
related_plan: ../superpowers/plans/2026-10-17-login-item.md
---

# 开机自动启动验证记录

## 自动化验证

- `xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode` 通过（xcresult：`Test-FastBudo-2026.10.17_15-38-50-+0800.xcresult`），既有测试无回归。
- `python3 -m unittest discover -s Tests/Bridge -v` 18 项通过。
- Release 构建通过；暂存至 `/tmp/fb-login-item/FastBudo.app` 后 `codesign --force --deep --sign -` 临时签名，`codesign -vv` 校验通过。

## 系统调用实测（探针）

命令行进程无辅助功能权限，无法驱动真实应用 UI；改用同签名方式的独立探针程序验证 `SMAppService` 行为。

- 探针：独立 bundle（`local.fastbudo.loginitem-probe`），ad-hoc 签名，直接调用 `register()` / `unregister()` / `status`。
- 结果：`register()` 成功，status 由 `.notFound` 变为 `.enabled`（本机未进入 `.requiresApproval`）；`unregister()` 成功，status 回到 `.notRegistered`。`LoginItem.swift` 依赖的全部系统调用与状态映射得到实测。
- 探针已注销并删除，系统未残留登录项。

## 手动验证步骤（待执行）

1. 安装新版 FastBudo.app 到 `~/Applications` 并打开，设置 → 通用 → 打开「开机自动启动」。
2. 确认「系统设置 → 通用 → 登录项」中出现 FastBudo。
3. 注销并重新登录，确认菜单栏出现 ⌘ 图标且不弹出设置窗。
4. 关闭开关，再次注销登录，确认不再自动启动。

## 未验证范围

- 应用重签重装后登录项的保持情况未实测：临时签名的指定要求为 cdhash，每次构建都会变化。若更新后失效，重新打开一次开关即可。
- `.requiresApproval` 引导与注册失败 alert 路径未在真机触发（本机注册直接成功）。

返回[文档索引](../README.md)。
