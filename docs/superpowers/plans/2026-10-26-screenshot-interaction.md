---
title: 截图界面与快捷键交互实施计划
status: active
last_updated: 2026-10-26
related_spec: ../specs/2026-10-26-screenshot-interaction-design.md
---

# 截图界面与快捷键交互 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development（推荐）或 executing-plans 逐任务执行；使用下面的复选框记录进度。当前会话已顺序实施，验证记录见下文。

**Goal:** 截图完成后仅展示图片与右下角功能按钮，截图/贴图快捷键可直接按键录入，设置页显示实际屏幕录制授权状态。

**Architecture:** 保留 ImageEditorModel 的像素坐标和导出逻辑，调整窗口壳与 SwiftUI 覆盖层。新增一个局部按键录入视图，沿用 ClipboardHotKey 与已有偏好，增加失败不覆盖的注册流程；权限状态由 ScreenshotController 按事件刷新。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Carbon、CoreGraphics；不加第三方依赖。

**Spec:** [截图交互调整设计](../specs/2026-10-26-screenshot-interaction-design.md)。基础能力见[第一批设计](../specs/2026-10-26-screenshot-pin-design.md)。

## Global Constraints

- Apple Silicon / macOS 27；Swift 6、SwiftUI/AppKit，无新增依赖。
- 保留图片大小/数量上限、无覆盖保存、异步编码、主线程 AppKit 操作及现有快捷键事件隔离。
- 用户已选择当前会话实施；不自动安装、提交、合并、推送。
- 复用当前 `codex/screenshot-pin` worktree。原有第一批未提交内容不得重置、覆盖或另建副本。
- 先 `bash scripts/build-engine.sh`，再执行 Xcode 构建/测试；新增 Swift 文件后运行 `xcodegen generate`，保留生成工程差异。

## 文件职责和影响范围

| 文件 | 改动责任 |
|---|---|
| `App/Screenshot/ImageEditor.swift` | 图片铺满内容区、右下角按钮及按需工具面板；保留模型和导出 |
| `App/Screenshot/ScreenshotController.swift` | 图片窗口尺寸、关闭回调、权限刷新、录入状态及偏好提交 |
| `App/Screenshot/ScreenshotSettings.swift` | 录入器替换原固定组合选择；权限状态展示与刷新触发 |
| 新增 `App/Screenshot/ShortcutRecorder.swift` | 录入视图、局部 NSResponder、组合校验/名称 |
| `App/Clipboard/ClipboardHotKey.swift` | 候选注册失败保留旧绑定，函数键支持及测试入口 |
| `App/Clipboard/ClipboardController.swift`、`App/AppDelegate.swift` | 录入时暂停/恢复剪贴板快捷键的窄回调 |
| `AppTests/ImageEditorTests.swift`、`AppTests/ScreenshotTests.swift` | 原有渲染与窗口行为回归；新尺寸/权限测试 |
| 新增 `AppTests/ShortcutRecorderTests.swift` | 组合、取消、冲突、偏好与注册回滚测试 |
| `Tests/ClipboardLifecycle/test_clipboard_lifecycle.py` | 真实 Carbon 路由及后台窗口回归 |
| `FastBudo.xcodeproj/project.pbxproj` | XcodeGen 生成新增源码/测试引用 |
| 使用指南、架构、变更日志、文档索引 | 实施完成后同步实际行为及验收证据 |

## 任务一：图片浮窗与右下角操作

**Files:** 修改 `App/Screenshot/ImageEditor.swift` 的 ImageEditor、ImageEditorCanvas、AnnotationCanvas；修改 ScreenshotController 的 `edit(_:)`；扩展 `AppTests/ImageEditorTests.swift`、`AppTests/ScreenshotTests.swift`。

**Interfaces:** 保留 `ImageEditorModel.rendered()`、`png()`、`save(to:)`。ImageEditor 初始化扩展为 `init(image: NSImage, onPin: @escaping (NSImage) -> Void, onClose: @escaping () -> Void)`；调用方只有 ScreenshotController.edit。ScreenshotController 新增纯函数 `static func editorFrame(imageSize: CGSize, visibleFrame: CGRect, scale: CGFloat) -> CGRect`，供窗口布局与测试使用。

- [x] **1. 先写布局回归测试**，同时保留现有原图尺寸/方向/导出测试。新增已校验图片的大小和跨屏坐标边界覆盖：

```swift
@Test func editorWindowFitsVisibleScreen() {
    let screen = CGRect(x: -1440, y: 200, width: 1440, height: 900)
    for size in [CGSize(width: 3840, height: 2160), CGSize(width: 80, height: 40),
                 CGSize(width: 300, height: 5000), CGSize(width: 6000, height: 300)] {
        let frame = ScreenshotController.editorFrame(imageSize: size, visibleFrame: screen, scale: 2)
        #expect(screen.contains(frame))
        #expect(frame.width > 0 && frame.height > 0)
    }
}
```

- [x] **2. 运行测试确认红灯来自缺失布局函数**，不是引擎或工程缺失：

```bash
bash scripts/build-engine.sh
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -only-testing:FastBudoTests/ScreenshotTests
```

- [x] **3. 实现窗口计算及无标题栏外壳**。目标屏幕按 `NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main` 选取，使用其 visibleFrame 与 backingScaleFactor。在 ScreenshotController 内实现：

```swift
static func editorFrame(imageSize: CGSize, visibleFrame: CGRect, scale: CGFloat) -> CGRect {
    let available = visibleFrame.insetBy(dx: 16, dy: 16)
    let width = max(1, imageSize.width), height = max(1, imageSize.height)
    let factor = min(1 / max(1, scale), min(available.width / width, available.height / height))
    let size = CGSize(width: min(available.width, max(240, width * factor)),
                      height: min(available.height, max(120, height * factor)))
    return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                  width: size.width, height: size.height)
}
```

`edit(_:)` 创建现有 PinnedImagePanel，样式改 `[.borderless, .nonactivatingPanel]`，不改贴图窗口本身。设置 `isOpaque = false`、透明背景，使用计算结果；继续保留委托、强持有窗口数组及关闭时释放 contentView。通过 `[weak window]` 的 onClose 回调关闭；仅手柄触发 `window.performDrag(with:)`，不得设置画布全区可拖动。

- [x] **4. 重排编辑界面，保留实际导出逻辑**。用下面骨架替换原 VStack，上方/下方栏删除；在同一 ImageEditor 内定义 `controls`、`toolOptions` 计算属性，不为这一组按钮新增通用组件框架。

```swift
ZStack(alignment: .bottomTrailing) {
    ImageEditorCanvas(model: model, revision: model.revision)
        .accessibilityLabel("截图标注画布")
    VStack(alignment: .trailing, spacing: 6) {
        if exporting { ProgressView("正在导出…") }
        controls
    }
    .padding(8)
}
```

`controls` 用 `ViewThatFits(in: .horizontal)`，先尝试一排图标，放不下时用两排；包含标注、撤销、重做、复制、保存、贴图、关闭及拖动手柄。`toolOptions` 用 `.popover(isPresented:)` 放现有工具 Picker、ColorPicker、笔宽 Slider 与文字 TextField。按钮全部 `.help` 和 `.accessibilityLabel`，当前工具有选中提示；沿用禁用条件与 Command+Z/Shift+Command+Z/Command+C/Command+S。

错误不得只存进被删除的常驻文案：将 `perform` 捕获的错误显示在操作组上方或 alert；成功反馈短暂显示。录入文字面板的 Escape 先收起面板，未展开时 Escape 执行 onClose。导出忙碌时禁用会更改图像的操作，不取消已获用户确认的保存。

- [x] **5. 画布改为透明且零内边距**。移除 `controlBackgroundColor` 填充及 imageRect 的 24 点扣减，使用 bounds 做等比 fit；继续以 imageRect 将事件映射到 model.size。工具面板和按钮只叠加在 SwiftUI 层，禁止通过窗口截图实现 PNG 导出。此步不重写 ImageEditorModel 的六工具渲染。

- [ ] **6. 验证**：重新运行 ImageEditorTests/ScreenshotTests；用合成小图、超宽图、竖图实操按钮与弹出面板；画布上下非对称标注导出后查看 PNG，确认无按钮、背景或控件残影。关闭后 editors 数量应减少，窗口不拉出设置页。只做布局改动不增加静态字符串测试。

## 任务二：直接录入快捷键与冲突回滚

**Files:** 新增 `App/Screenshot/ShortcutRecorder.swift`、`AppTests/ShortcutRecorderTests.swift`；修改 ScreenshotSettings、ScreenshotController、ClipboardHotKey、ClipboardController、AppDelegate 及生成工程。

**Interfaces:** 在 ShortcutRecorder.swift 定义值类型 `RecordedShortcut: Equatable`（`key: UInt32`、`modifiers: UInt32`、`label: String`）以及 `static func accepts(key: UInt32, modifiers: UInt32) -> Bool`；SwiftUI `ShortcutRecorder` 接收当前显示名、`onRecordingChanged: (Bool) -> Void`、`onCommit: (RecordedShortcut) -> Bool`。内嵌 NSView 捕获局部 keyDown/performKeyEquivalent/flagsChanged/keyUp，单独修饰键只更新预览。

ScreenshotController 定义 `enum ShortcutAction { case capture, paste }`、`setShortcutRecording(_ active: Bool)`、`commitShortcut(_ shortcut: RecordedShortcut, for action: ShortcutAction) -> Bool` 和 `shortcutRecordingChanged: (Bool) -> Void` 回调。ClipboardController 增加 `setShortcutRecordingPaused(_ paused: Bool)`；AppDelegate 在启动时接回调，避免 ScreenshotController 直接持有另一个 controller。

- [x] **1. 先写输入校验测试**。普通组合必须包含 Control 或 Command，F1–F20 允许不带修饰键；Escape 与纯修饰键由录入器处理，不进入提交。

```swift
@Test func recordedShortcutValidation() {
    #expect(RecordedShortcut.accepts(key: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey)))
    #expect(RecordedShortcut.accepts(key: UInt32(kVK_F1), modifiers: 0))
    #expect(!RecordedShortcut.accepts(key: UInt32(kVK_ANSI_K), modifiers: 0))
    #expect(!RecordedShortcut.accepts(key: UInt32(kVK_Shift), modifiers: UInt32(shiftKey)))
}
```

- [ ] **2. 生成工程并运行新增测试确认缺失实现导致失败**：

```bash
xcodegen generate
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -only-testing:FastBudoTests/ShortcutRecorderTests
```

- [x] **3. 实现录入值与局部录入器**。注册值只保留四类 Carbon 修饰键，不能直接把 NSEvent.ModifierFlags.rawValue 作为 Carbon 值：

```swift
func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
    var result: UInt32 = 0
    if flags.contains(.control) { result |= UInt32(controlKey) }
    if flags.contains(.option) { result |= UInt32(optionKey) }
    if flags.contains(.shift) { result |= UInt32(shiftKey) }
    if flags.contains(.command) { result |= UInt32(cmdKey) }
    return result
}
```

函数键集合使用 Carbon 的 kVK_F1 到 kVK_F20 常量逐个枚举，不能假设 keyCode 连续。修饰键 keyCode 明确拒绝。普通键名采用录入事件 `charactersIgnoringModifiers`，空格、方向、删除、Return、Tab、函数键用显式名称，避免显示控制字符；按 ⌃⌥⇧⌘ 顺序拼接。新增 screenshotKeyLabel/pinKeyLabel 保存录入名称；旧设置未存名称时从既有键码映射 S/P/C/V/空格，不丢弃原组合。

NSView 通过成为 firstResponder 开始录入，`performKeyEquivalent` 在录入期间消费本窗口的 Command 组合，再转交同一个处理函数；keyDown 非重复事件形成候选，keyUp 完成提交。Escape 取消，resignFirstResponder/viewWillMove(toWindow:nil) 清理；没有待提交按键时不注册。录入期间不能让普通文本输入/退出/菜单命令顺带执行。控件不要使用全局 event tap。

- [x] **4. 修改 ClipboardHotKey.register 为失败保留原绑定**。新增 `currentBinding` 缓存仅表示成功的当前注册；stop 清空。核心顺序如下，事件 handler 安装仍沿用现有实现：

```swift
if currentBinding?.key == key && currentBinding?.modifiers == modifiers && hotKey != nil { return true }
guard Self.accepts(key: key, modifiers: modifiers) else { return false }
var candidate: EventHotKeyRef?
let status = RegisterEventHotKey(key, modifiers,
    EventHotKeyID(signature: 0x46424350, id: identifier),
    GetApplicationEventTarget(), 0, &candidate)
guard status == noErr else { return false }
if let hotKey { UnregisterEventHotKey(hotKey) }
hotKey = candidate
currentBinding = (key: key, modifiers: modifiers)
return true
```

不要在进入 register 时先 Unregister；注册失败不更改 action、旧 ref 或 currentBinding。`currentBinding` 类型是 `(key: UInt32, modifiers: UInt32)?`，不需要额外注册管理类。共享类不要依赖 SwiftUI 录入视图：accepts 的纯校验放在 ClipboardHotKey 静态方法中，RecordedShortcut.accepts 转调它。

- [x] **5. 连接暂停、提交与恢复**。ScreenshotController.setShortcutRecording(true) 停止 snipKey/pasteKey，回调暂停剪贴板；false 按持久化设置恢复并回调恢复剪贴板。ClipboardController 在 configureShortcut 中遵守暂停状态，设置页切换设置也不能绕过暂停。

configureShortcuts 在录入期间不处理 AppStorage 通知；正常重配不先 stop 两个 ref，只有关闭总开关时 stop。commitShortcut 先检查与另一个截图入口和启用中的剪贴板组合重复，再调用目标 register；失败立即恢复旧偏好对应的注册，不写 defaults。成功才连续写 key/modifiers/label；结束录入时相同组合的 register 走无操作分支，避免自己与自己冲突。不要用 key/modifiers 的独立 Binding setter 直接注册中间态。

AppDelegate 连接示例（新增接口已在本任务定义）：

```swift
screenshot.shortcutRecordingChanged = { [weak self] active in
    self?.clipboard.setShortcutRecordingPaused(active)
}
```

设置页将原 modifier checkbox 和有限 Picker 替换为两个 ShortcutRecorder，分别转调 `.capture`、`.paste`；总开关和现有注册状态提示保留。停止 controller、关闭设置、切页、失焦均结束录入恢复原状态；恢复失败显示实际失败状态，不静默宣称原组合可用。

- [x] **6. 测试取消和冲突回滚**。用唯一 UserDefaults suite 创建 ScreenshotController，不使用用户持久化偏好；测试下列用例：

```swift
@Test @MainActor func duplicateShortcutDoesNotOverwritePreferences() {
    let name = "ShortcutTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(1, forKey: "screenshotKey")
    defaults.set(35, forKey: "pinKey")
    defaults.set(Int(controlKey | shiftKey), forKey: "pinModifiers")
    let controller = ScreenshotController(defaults: defaults)
    defer { controller.stop() }
    let duplicate = RecordedShortcut(key: 35, modifiers: UInt32(controlKey | shiftKey), label: "⌃⇧P")
    #expect(!controller.commitShortcut(duplicate, for: .capture))
    #expect(defaults.integer(forKey: "screenshotKey") == 1)
}
```

补同套测试：录入→取消不改四个现有 key；已关闭的剪贴板组合不算内部冲突；录入时截图 action 不被调用；结束后三个入口按原 enabled 状态恢复。注册失败回滚用专用 Carbon 测试实例（不同 identifier）占用候选组合；不仅向旧 ID 发送事件检查路由，还必须验证旧组合仍被占用，原实例 stop 后才可被其他实例注册。仅发送合成事件无法证明系统绑定仍然存在。参考测试如下，不触碰用户默认组合：

```swift
@Test @MainActor func failedRegistrationRetainsOldSystemBinding() {
    let owner = ClipboardHotKey(identifier: 201)
    let blocker = ClipboardHotKey(identifier: 202)
    let probe = ClipboardHotKey(identifier: 203)
    defer { owner.stop(); blocker.stop(); probe.stop() }
    let modifiers = UInt32(controlKey | optionKey | cmdKey)
    let old = UInt32(kVK_F18), candidate = UInt32(kVK_F19)
    guard owner.register(key: old, modifiers: modifiers),
          blocker.register(key: candidate, modifiers: modifiers) else {
        Issue.record("隔离测试组合已被外部应用占用，无法建立回滚测试前置条件")
        return
    }
    #expect(!owner.register(key: candidate, modifiers: modifiers))
    #expect(!probe.register(key: old, modifiers: modifiers))
    owner.stop()
    #expect(probe.register(key: old, modifiers: modifiers))
}
```

所有测试注册在 defer 中释放。实际机器若候选被外部应用预先占用，明确记录环境原因而非跳过断言冒充通过。

- [ ] **7. 验证交互**：真实设置页录入一组新快捷键，取消、切页、关闭、冲突、重新启动均检查；确认 Command 组合不会提前执行应用菜单动作，输入时旧快捷键不会触发，修饰键松开后才能恢复。更新原有 Carbon 生命周期测试，保留明确 EventHotKeyID；不要回退为广播事件。

## 任务三：屏幕录制启用状态

**Files:** ScreenshotController.swift、ScreenshotSettings.swift、AppTests/ScreenshotTests.swift。

**Interfaces:** ScreenshotController 新增 `private(set) var screenCaptureAuthorized = false` 和 `func refreshScreenCapturePermission()`。init 增加 `screenCaptureAccess: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() }` 参数；保存为私有闭包用于只读状态检查，其他现有调用无需变化。不把 CGRequest 包进这个只读接口。

- [x] **1. 写无系统授权副作用的状态测试**：

```swift
@Test @MainActor func permissionStatusRefreshesFromSystemProbe() {
    var allowed = false
    let controller = ScreenshotController(screenCaptureAccess: { allowed })
    controller.refreshScreenCapturePermission()
    #expect(!controller.screenCaptureAuthorized)
    allowed = true
    controller.refreshScreenCapturePermission()
    #expect(controller.screenCaptureAuthorized)
    allowed = false
    controller.refreshScreenCapturePermission()
    #expect(!controller.screenCaptureAuthorized)
}
```

- [ ] **2. 运行 ScreenshotTests 看到新接口缺失失败，再添加状态**：

```swift
func refreshScreenCapturePermission() {
    screenCaptureAuthorized = screenCaptureAccess()
}
```

捕获入口先 refresh，再根据 screenCaptureAuthorized 决定是否请求权限；请求后再 refresh，成功继续截图，失败给出系统设置/可能重启提示。不能将 request 的返回值或设置页打开成功视为状态真相。

- [x] **3. 设置页显示状态并事件刷新**：

```swift
Label(controller.screenCaptureAuthorized ? "屏幕录制 · 已启用" : "屏幕录制 · 未启用",
      systemImage: controller.screenCaptureAuthorized ? "checkmark.circle.fill" : "exclamationmark.circle")
    .foregroundStyle(controller.screenCaptureAuthorized ? Color.green : Color.secondary)
```

截图 Section 的系统设置按钮在未授权时显示。将刷新放在整个 ScreenshotSettings 根容器的 `.onAppear` 和 `.onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))` 中；不只挂在可能未显示的某个 Section 上，不增 timer。检查刷新不会触发系统授权弹窗。

- [ ] **4. 回归状态测试，并真实验证**：已有权限显示已启用；未授权显示未启用；从系统设置返回能刷新；系统要求重启时如实提示。测试不自动点击系统授权开关；涉及新增安全权限时由用户授权完成，记录实际结果与剩余边界。

## 任务四：集成验收与文档

**Files:** `docs/guides/screenshot-pin.md`、`ARCHITECTURE.md`、`CHANGELOG.md`、`docs/README.md`、本设计/计划及生成工程。

- [x] **1. 运行最终回归**，先引擎，避免真实窗口测试并发抢焦点：

```bash
bash scripts/build-engine.sh
xcodegen generate
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode
python3 -m unittest discover -s Tests/ClipboardLifecycle -v
xcodebuild -scheme FastBudo -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
```

- [ ] **2. 逐项实际验收**：截图浮窗无标题/上下栏，右下角按钮在小图和多屏均可达；六工具与撤销/重做保留，保存 PNG 无 UI；录入取消/冲突/重启/焦点恢复；屏幕权限显示。源码级或模拟权限测试不得标记真实授权流程已通过。
- [x] **3. 同步实际文档**：使用指南改为图片浮窗、录入式快捷键与授权状态；变更日志只写未发布条目；架构补局部录入与事务注册、事件刷新；索引保留本设计/计划入口。未执行项继续保留未完成标记，旧验证记录不改成新功能证据。
- [x] **4. 文档与差异门禁**：

```bash
python3 "$HOME/.codex/skills/ai-project-standards/scripts/validate-project-standards.py" --root .
python3 scripts/check-private-paths.py
git diff --check
```

检查本次新建 Markdown 的所有相对链接能解析。交付时给出改动、测试和未测范围；不默认重新安装。若用户随后明确要求安装，再复用 sign-local.sh、原安装位置和可恢复备份流程。

## 执行交接

两个可选方式：子智能体逐任务实施并做需求/质量审查；或当前会话按顺序实施。选择后执行四个任务，不在任务间重复索取同一授权。当前不创建提交；如用户后续授权提交，先执行 enforce-conventions 提交阶段、暂存隐私检查，使用中文提交说明和实际 Agent 署名。

## 实施记录

已完成三个功能及集成，测试和实机边界见[截图与贴图指南](../../guides/screenshot-pin.md)。未勾选的混合验收项保留未测部分；任务二、三没有独立执行编译红灯阶段，不补写为已执行。

实际布局按宽度 340 点切换单双排，避免 ViewThatFits 重复创建标注弹窗。录入采用普通 keyUp 与全部修饰键释放双路径，兼容 AppKit Command 等价键吞 keyUp；对应回归测试通过。共享注册的冲突保留使用真实 Carbon 占用验证，不以合成事件替代。没有新增依赖或改写图片导出模型。
