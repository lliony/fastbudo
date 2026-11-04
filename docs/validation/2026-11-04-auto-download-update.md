---
title: 自动下载更新设置验证
status: active
last_updated: 2026-11-04
---

# 自动下载更新设置验证

实现边界见 [架构文档](../../ARCHITECTURE.md)，变化见 [变更日志](../../CHANGELOG.md)，导航见 [文档索引](../README.md)。

## 改动与行为

- 新增 `UpdatePreferences.autoDownloadKey`（`autoDownloadUpdates`，默认关闭），设置页「版本更新」展示开关。
- 开关开启时：AppDelegate 在启动 30 秒后静默检查一次，发现新版本直接走既有 `UpdateInstaller.prepare` + `installUpdate`（下载、校验、解压、验证、目录交换、退出并重启）；设置页手动检查发现新版本时也跳过确认直接进入进度界面。归档任务进行中跳过，检查或安装失败静默，留待下次启动重试，不弹窗。
- 开关关闭时行为不变：手动检查 → 结果弹框 → 「立即更新」确认。

## 自动验证

- `bash scripts/build-engine.sh` 通过。
- `python3 -m unittest discover -s Tests/Bridge -v`：19 项通过。
- `xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode`：154 项（21 套）通过，含更新检查分类、下载限制、目录交换回滚与重启脚本恢复。
- `python3 -m unittest discover -s Tests/UpdateLifecycle -v`：1 项真实窗口生命周期测试通过；探针复用 `AppDelegate`，验证新增的启动调度不干扰既有安装退出时序（探针全程短于 30 秒延迟，且默认关闭开关）。

## 边界与未测范围

- 开启开关后从启动检查到自动重启的完整链路复用已验证的手动更新实现，本次未实测「真实发现更高正式版并自动完成重启」；当前更新源无高于 0.0.8 的正式版可供端到端验证。
- 自动下载设置项的界面呈现与开关切换为 SwiftUI 声明式实现，未做真实界面操作验证。
- 未在 Intel 真机验证；未验证长时间断网、限流期间开启开关的行为（预期为静默跳过，下次启动重试）。
