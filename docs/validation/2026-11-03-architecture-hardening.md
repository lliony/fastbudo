---
title: 性能、内存与崩溃防护加固验证
status: active
last_updated: 2026-11-03
---

# 性能、内存与崩溃防护加固验证

返回[文档索引](../README.md)。架构背景见[架构文档](../../ARCHITECTURE.md)，用户可见变化见[变更日志](../../CHANGELOG.md)。

本轮针对截图/贴图、剪贴板、归档三条数据流做定向加固，重点是内存峰值、主线程与锁内耗时，以及一个可导致整进程退出的信号问题。未改变应用边界、数据库路径、备份格式或第三方引擎版本。

## 改动范围

- 截图渲染管线：`ImageEditorModel` 按 revision 缓存全分辨率渲染结果，画布另存显示分辨率副本；标注变化或画布尺寸变化超过四分之一时重建。复制、保存和贴图共用同一份全图结果，拖动画笔不再逐帧缩放原图。
- 贴图窗口所有权：`PinnedImage` 自身作为面板 delegate，关闭时断开模型→面板→视图持有环并回调 `onClosed`；ESC、标题栏和控制器三条关闭路径语义一致。控制器不再手动执行断环。
- 区域选区接缝：完成结果改为携带 `captureRect`、`screenFrame` 与 `copyToClipboard` 的 `RegionSelection`，面板经 `takeTransferredPanel()` 显式转交；屏幕与截图坐标的三处翻转集中到 `CaptureGeometry`。未用于编辑的已转交面板在清理阶段关闭。
- 剪贴板存储：schema 2 → 3，把 `used`、`pinned`、`protected`、`kind` 提升为列并建立排序索引；列表排序、搜索与清理聚合下推 SQL。负载校验、编码与 SHA-256 移到锁外，事务只做数据库操作。最近使用比较规则收敛为 `ClipboardItem.precedes`。
- 归档引擎：初始化时忽略 `SIGPIPE`；密码管道写入失败不再中断流程，继续读取子进程结构化错误并按任务失败处理。

## 验证环境与结果

环境：Apple Silicon / macOS 27，仓库内固定 7zip 源码构建的引擎，`SWIFT_VERSION 6.0` 严格并发检查。

```bash
bash scripts/build-engine.sh
python3 -m unittest discover -s Tests/Bridge -v
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode
python3 -m unittest discover -s Tests/Performance -v
xcodebuild -scheme FastBudo -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
```

- Bridge：19 项通过。
- App：154 项 / 21 套通过，包含新增的渲染缓存复用、显示缓存尺寸容差与方向、贴图直接关闭断环、坐标换算往返、schema 2 迁移、排序规则单源及 SIGPIPE 断管写入用例。
- Performance：256 MiB 复制峰值 10,600,448 字节，低于 128 MiB 上限；本轮未改动复制路径。
- Release 构建：`arm64` 成功。

## 未覆盖边界

- 截图/贴图的内存峰值与帧率没有用 Instruments 或常驻探针实测；测试只断言渲染与显示缓存的构建次数，不能替代真实大图交互下的内存曲线。
- 剪贴板迁移在测试中通过建库后移除新增列模拟 schema 2；未用真实长期使用的线上数据库副本验证，也未覆盖磁盘写满时的迁移回滚。
- 真实屏幕录制权限流程、多屏混合缩放、Finder 菜单与安装包仍需人工验证。
- 本次未打标签、未上传安装包，也未在 Intel 硬件验证。
