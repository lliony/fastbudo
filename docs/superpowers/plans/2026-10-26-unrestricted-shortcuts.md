---
title: 快捷键自由录入实施计划
status: active
last_updated: 2026-10-26
related_spec: ../specs/2026-10-26-unrestricted-shortcuts-design.md
---

# 快捷键自由录入 Implementation Plan

> **For agentic workers:** 使用 executing-plans 顺序实施，或用户选择后使用 subagent-driven-development；复选框记录实际完成情况。

**Goal:** 取消截图与贴图快捷键的组合限制，保留冲突检测和失败回滚。

**Architecture:** 放宽共享注册的结构校验，局部录入器将 Escape 作为候选，点击同一按钮取消；沿用控制器的冲突、事务注册和持久化流程。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Carbon，无新增依赖。

**Spec:** [自由录入设计](../specs/2026-10-26-unrestricted-shortcuts-design.md)。

## Global Constraints

- Apple Silicon / macOS 27，不新增全局键盘监听或权限。
- 保留默认组合、偏好键、剪贴板设置页结构和图片编辑器 Escape 行为。
- 复用现有工作区，保留全部未提交工作；不自动安装、提交、推送。
- 只声明本应用重复检查和系统注册反馈，不宣称检测所有其他应用局部操作。

## Task 1：允许自由录入并保留取消

**Files:** 修改 App/Clipboard/ClipboardHotKey.swift、App/Screenshot/ShortcutRecorder.swift、AppTests/ShortcutRecorderTests.swift。

**Interfaces:** 保留 accepts(key:modifiers:)、RecordedShortcut.init?(event:)、RecorderButton.finish() 的现有签名。

- [x] **1. 更新 validCombinations 测试。** 删除拒绝裸 K 和 Escape 的旧断言，保留 Command / F1 原覆盖，增加：

~~~swift
for key in [kVK_ANSI_K, kVK_ANSI_1, kVK_Space, kVK_Escape, kVK_LeftArrow] {
    for modifiers in [0, shiftKey, optionKey, shiftKey | optionKey] {
        #expect(ClipboardHotKey.accepts(key: UInt32(key), modifiers: UInt32(modifiers)))
    }
}
#expect(!ClipboardHotKey.accepts(key: 128, modifiers: 0))
#expect(!ClipboardHotKey.accepts(key: UInt32(kVK_Command), modifiers: UInt32(cmdKey)))
#expect(!ClipboardHotKey.accepts(key: 1, modifiers: UInt32.max))
~~~

- [x] **2. 运行红灯测试，确认失败来自旧限制。**

~~~bash
bash scripts/build-engine.sh
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -only-testing:FastBudoTests/ShortcutRecorderTests
~~~

- [x] **3. 替换 accepts 实现。** functionKeys 留作名称映射，注册成功才释放旧绑定的顺序不变。

~~~swift
nonisolated static func accepts(key: UInt32, modifiers: UInt32) -> Bool {
    key <= 127 &&
    ![54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(key) &&
    modifiers & ~UInt32(controlKey | cmdKey | optionKey | shiftKey) == 0
}
~~~

- [x] **4. 修改名称与取消路径。** special 字典加入 53: "Esc"，删除空名称 guard；初始化 label 使用下列表达式，避免特殊键因没有可打印字符被拒绝：

~~~swift
Self.modifierLabel(modifiers) + (name.isEmpty ? "按键 " + String(key) : name)
~~~

begin 开头替换为以下代码，后续失焦 observer 保留：

~~~swift
if recording { finish(); return }
guard window?.makeFirstResponder(self) == true else { return }
recording = true
title = "请按快捷键，再次点击取消"
changed(true)
~~~

删除 keyDown 中 event.keyCode == 53 的取消分支，失败文案改为“请按一个按键或组合键”。保留 keyUp 和全部修饰键松开两条提交路径。

- [x] **5. 新增录入器回归测试。**

~~~swift
@Test @MainActor func escapeRecordsAndClickCancels() throws {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 80),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let button = ShortcutRecorder.RecorderButton()
    window.contentView = button
    defer { window.close() }
    var saved: RecordedShortcut?
    var transitions: [Bool] = []
    button.commit = { saved = $0; return true }
    button.changed = { transitions.append($0) }
    button.performClick(nil)
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = try #require(NSEvent.keyEvent(with: type, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_Escape)))
        if type == .keyDown { button.keyDown(with: event); #expect(saved == nil) }
        else { button.keyUp(with: event) }
    }
    #expect(saved?.label == "Esc")
    button.performClick(nil)
    button.performClick(nil)
    #expect(!button.recording)
    #expect(saved?.label == "Esc")
    #expect(transitions == [true, false, true, false])
}

@Test @MainActor func unnamedKeyHasPhysicalLabel() throws {
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 10))
    #expect(RecordedShortcut(event: event)?.label == "按键 10")
}
~~~

- [x] **6. 重跑步骤 2 的定向测试至通过。** 保留真实 Carbon 占用回滚测试，不把外部占用前置条件失败改为跳过或通过。

## Task 2：冲突反馈与集成验收

**Files:** 修改 App/Screenshot/ScreenshotSettings.swift、App/Screenshot/ScreenshotController.swift、App/Clipboard/ClipboardController.swift、AppTests/ShortcutRecorderTests.swift；同步 docs/guides/screenshot-pin.md、CHANGELOG.md、docs/README.md 和本设计/计划。

**Interfaces:** 保留 commitShortcut(_:for:) 和暂停恢复回调，不新增持久化字段。消费 Task 1 放宽后的校验。

- [x] **1. 更新文案。** ScreenshotSettings 删除必须包含修饰键及 Esc 取消说明，改为：

~~~swift
Text("点击后直接录入单键或组合键，再次点击或移开焦点取消。冲突时保留原设置。全局单键可能影响日常输入。")
    .font(.caption).foregroundStyle(.secondary)
~~~

ScreenshotController 注册失败提示改为“快捷键已被占用或系统不支持，原设置已保留”；ClipboardController 删除“需包含 Control 或 Command”，保留不可用或占用提示。

- [x] **2. 扩充 conflictDoesNotPersistAndCancellationResumes。** 在原冲突断言之后、结束录入之前插入：

~~~swift
defaults.set(Int(kVK_ANSI_K), forKey: "pinKey")
defaults.set(0, forKey: "pinModifiers")
#expect(!controller.commitShortcut(
    RecordedShortcut(key: UInt32(kVK_ANSI_K), modifiers: 0, label: "K"), for: .capture))
#expect(defaults.integer(forKey: "screenshotKey") == 1)
#expect(!defaults.bool(forKey: "screenshotHotKeysEnabled"))
~~~

保留该测试的暂停/恢复断言和独立 suite 清理。

- [x] **3. 顺序执行自动验证，避免窗口测试抢焦点。**

~~~bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode
python3 -m unittest discover -s Tests/ClipboardLifecycle -v
xcodebuild -scheme FastBudo -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
~~~

不新增源文件，不修改 project.yml，无需无故重新生成工程。

- [ ] **4. 隔离探针实测。** 使用独立 bundle/defaults、关闭全局截图入口，录入 K、1、Shift+K、Option+K、Esc、F1、Command+Shift+K。检查成功项保存、重启保留，注册失败明确反馈。检查再次点击、失焦、切页、关闭取消后暂停解除。系统占用结果记录为真实边界，不改用户快捷键或系统权限。探针结束停止全部注册。

- [x] **5. 同步文档与门禁。** 指南替换强制修饰键和 Esc 取消规则；变更日志写未发布；旧设计标明对应规则已由新设计取代；本计划更新实际完成项和测试证据，不将未测项标为通过。

~~~bash
python3 "$HOME/.codex/skills/ai-project-standards/scripts/validate-project-standards.py" --root .
python3 scripts/check-private-paths.py
git diff --check
~~~

检查本轮新增 Markdown 相对链接。提交、安装与推送另行授权。

## 执行交接

可选择当前会话顺序执行，或子智能体逐任务实施与审查。沿用先前偏好推荐当前会话顺序执行，选定后不在各任务之间重复请求授权。

## 实施结果

代码与自动验证完成：102 项应用测试、ClipboardLifecycle、Release 和文档门禁通过。实际探针录入与冲突结果见[指南](../../guides/screenshot-pin.md)。任务 2 步骤 4 保留未勾选：录入、点击取消、失焦转移、重启保留和重复单键冲突已实测；切页及关闭时录入状态未重复 UI 验收。

没有新增源文件或依赖，没有重新安装、提交、推送，既有工作区改动保留。
