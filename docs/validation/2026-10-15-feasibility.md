---
title: 首版技术验证记录
status: active
last_updated: 2026-10-15
---

# 首版技术验证记录

关联[设计](../superpowers/specs/2026-10-15-fastbudo-design.md)和[计划](../superpowers/plans/2026-10-15-fastbudo.md)。当前仅为技术验证阶段，不是可用压缩应用。

## 环境与工程

Apple Silicon、macOS 27.0.1、Xcode 27.0、Swift 6.4。工程使用本机已有 XcodeGen 生成，提交生成后的 Xcode 工程；打开工程构建不依赖额外安装 XcodeGen。project.yml 是工程配置来源，改动后重新生成。

已创建 AppKit 系统服务声明、两个服务回调、文件打开事件及只显示接收文件的 SwiftUI 验证窗口。界面明确说明不执行压缩/解压。尚未安装至 Applications，也未在真实 Finder 菜单中验证服务出现及启用，因此任务 1 未完成。

## 测试证据

命令：`xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode`。

ServiceInputTests 覆盖有序传递两个本地 URL、空请求及网络 URL 拒绝。先以抛出 noFiles 的实现观察到 preservesFileOrder 失败，完成转换后通过；服务回调加入后再次构建和测试通过。

## 官方引擎验证

下载来源：https://github.com/ip7z/7zip/releases/download/26.04/7z2604-mac.tar.xz

包 SHA-256：`bee04358cbcbc7106273cee0e8d72916db2696c48067a3538c34d8cd6fd16578`。此值是下载后本地计算的内容指纹，不是独立上游签名验证。

7zz 自报版本 26.04 arm64。合成文本文件分别创建 ZIP、7z、TAR、GZIP 并执行 `7zz t`，均退出 0。此为基本烟雾测试，不代表完整格式验收。

通过 `7zz a -t7z -p -mhe=on` 创建加密归档，随机临时密码仅从 stdin 输入；`7zz t` 从 stdin 接收同一密码并成功。创建和测试输出均未回显密码。尚未验证 ZIP AES、错误密码重试、取消时行为、RAR 与分卷及实际进程观察，因此任务 2 未完成。

引擎仅下载在 /private/tmp/fastbudo-engine-probe，不加入正式应用或仓库。未分发二进制，完整许可证与源码供应工作仍属于实施任务。

## 安全枚举的阻塞证据

用两个 ZIP 分别保存文件名 `a<换行>b` 和 `a_b`，内容、时间及属性一致。`7zz l -slt -ba` 输出逐字节相同，均为 `Path = a_b`；实际解压分别得到原始换行名称和下划线名称。不能从文本列表恢复原始路径。

复现命令：`python3 scripts/probe-7zip-listing.py /absolute/path/to/7zz`。脚本只在独占临时目录中创建并解压正常合成文件，结束自动清理。断言同时验证“输出相同”和“实际名称不同”，避免把显示问题误当作提取行为。

结论仅限：该文本输出不足以作为原始条目路径的可靠来源；不是宣称已经证明 7-Zip 本身可被路径穿越利用。

依设计 §6 和计划任务 3，不能继续把文本列表当安全边界来开放通用解压。建议读取引擎结构化接口，暴露原始路径、类型、大小及受控输出回调；这将引入少量 C/C++ 桥接和上游构建维护。仍需验证密码、分卷、链接属性及受控写入接口覆盖范围。

尝试下载官方源包及固定版本头文件时遭遇 TLS 连接错误，尚未确认具体桥接签名或构建方式。不将接口可用性写成已验证事实。

## 继续实施的条件

需要确认调整引擎集成路线：保留完整产品范围，新增结构化引擎桥接验证任务，替代纯 CLI 安全预检。确认后先取得固定版本源码、验证原始文件名枚举与受控写入，再继续任务 3–8；此前已有 Finder 入口工程和测试可复用。

没有完成全量格式、元数据往返、文件安全或用户交互验收，不生成可供日常使用的安装包。
