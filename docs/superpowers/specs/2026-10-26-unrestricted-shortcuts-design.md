---
title: 快捷键自由录入设计
status: active
last_updated: 2026-10-26
related_plan: ../plans/2026-10-26-unrestricted-shortcuts.md
---

# 快捷键自由录入

用户要求取消录入组合限制，只保留冲突检查。见[计划](../plans/2026-10-26-unrestricted-shortcuts.md)与[索引](../../README.md)。本设计取代[上轮设计](2026-10-26-screenshot-interaction-design.md)中强制 Control / Command 和 Escape 取消的规则，已在工作区实施，尚未安装；验证见[指南](../../guides/screenshot-pin.md)。

## 行为

允许普通单键、数字、空格、导航键、功能键、Escape，以及 Shift、Option、Control、Command 组合。不以缺少修饰键或无法生成友好名称拒绝输入；名称缺失显示物理键码。

Escape 也可绑定，取消改为再次点击录入按钮或失焦、切页、关闭窗口。录入时仍暂停三个全局入口，局部事件仍由录入器接收，避免 Command+Q 导致退出。“不拦截”指不做产品层组合限制。

保留键码和修饰位结构校验。单独修饰键只有 flagsChanged，不构成既有 Carbon 的主键加修饰键模型；不新增全局监听来模拟。系统未传递的事件无法录入，注册失败明确提示占用或系统不支持。

## 冲突与范围

继续检查截图、贴图及已启用剪贴板入口的重复，外部占用由系统注册判断。成功才保存；失败保留原偏好和绑定；相同组合重复提交成功。禁用状态修改不偷偷启用快捷键。

不能保证检测其他应用所有局部菜单和文本输入快捷操作，也不能保证未来不被抢占。页面说明全局单键可能影响日常输入，不新增确认弹窗。

Swift 6 / SwiftUI / AppKit / Carbon，Apple Silicon / macOS 27，无新增依赖。保留默认组合与偏好键；剪贴板设置页结构不变，删除共享注册调用方的过期提示。图片编辑器 Escape 关闭不变。

## 验收

测试裸字母、数字、Shift / Option 组合、Escape、无名称回退、点击取消、冲突回滚、禁用状态。隔离探针验证录入和重启持久化，不改用户偏好。实现后构建 Release；安装、提交和推送另行授权。
