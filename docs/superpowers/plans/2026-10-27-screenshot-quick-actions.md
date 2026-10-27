---
title: 截图 ESC 关闭与快速输出实施计划
status: active
last_updated: 2026-10-27
related_spec: ../specs/2026-10-27-screenshot-quick-actions-design.md
---

# 截图 ESC 关闭与快速输出 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 一次 ESC 关闭当前截图，并提供跳过编辑器的区域截图复制与另存为入口。

**Architecture:** 保留 ScreenshotController 的权限、箭头选区、进程和串行生命周期，将本次输出目标作为不可变值传入完成回调。复用 ImageEditorModel 的 PNG 编码及无覆盖保存；ESC 使用仅限当前编辑器及其工具弹层的局部按键处理；快捷键沿用 Carbon 和现有录入器。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Carbon、CoreGraphics、Swift Testing、XcodeGen；无新增依赖。

**Spec:** [截图 ESC 关闭与快速输出设计](../specs/2026-10-27-screenshot-quick-actions-design.md)。执行前同时阅读其“用户已确认的交互”和边界；不以旧设计的“ESC 先收起弹层”覆盖本次要求。

## Global Constraints

- Apple Silicon / macOS 27；Swift 6、SwiftUI/AppKit，不新增第三方依赖。
- AppKit 窗口与剪贴板操作留在主线程；图片编码、文件读写留在后台。
- 保留明亮中国红、原应用图标、现有区域选取层、原截图/贴图快捷键及现有偏好。
- 保留 20 MiB、单边 20000 像素、总计四千万像素及最多两个截图编辑器的边界。
- 输出 PNG 保留原图像素和方向，拒绝覆盖任何已有文件；取消选区不写剪贴板或输出文件。
- 测试仅使用合成图片、独立剪贴板和专用临时目录；不修改用户快捷键或测试用户文件。
- 当前截图工作区含大量未提交改动，不重置、不覆盖、不把旧历史合并或推送到主分支。
- 用户已选择子代理逐任务实施；不自动提交、安装、合并、推送或发布。

---

## 执行基线与文件职责

“本轮只编写计划”限制本文档产出轮次；用户选择实施后再执行下面任务，该选择不包含安装、推送或发布授权。

实际截图源码在现有 `codex/screenshot-pin` 工作区；当前聊天原挂载的 `codex/red-settings-ui` 不包含截图模块。执行时先 `git worktree list`、`git status --short` 和 `git log -1 --oneline`，找到含 `App/Screenshot/ScreenshotRegionSelector.swift` 的工作区。复用该隔离区，不另建缺少未提交截图功能的工作区，不修改其他聊天。先保存本轮涉及文件的变更前快照，后续评审以快照差异识别本轮增量。

| 文件 | 责任 |
|---|---|
| `App/Screenshot/ImageEditor.swift` | 当前图 ESC 路由及局部监听生命周期，保留像素模型 |
| `App/Screenshot/ScreenshotController.swift` | 输出动作、权限/选区/进程/输出接线、快捷键冲突和注册 |
| `App/Screenshot/ScreenshotSettings.swift` | 快速操作入口与两个可选快捷键录入/清除 |
| `App/FastBudoApp.swift` 的 `StatusPopover` | 菜单栏两个快速区域入口 |
| `AppTests/ImageEditorTests.swift` | ESC 范围、弹层与保存面板行为 |
| `AppTests/ScreenshotTests.swift` | 输出分派、独立剪贴板、实际文件和无覆盖回归 |
| `AppTests/ShortcutRecorderTests.swift` | 新组合缺省、冲突、清除、事件 ID 和旧偏好兼容 |
| 现有指南、架构、变更日志、文档索引 | 实施完成后记录实际行为、测试和未测边界 |

不新增服务层、插件、通用快捷键框架或新图片格式。现有 `PinnedImagePanel` 是 `final`，不在计划里继承它，也不为了 ESC 放开该类的封闭性。以下代码放进现有文件，原则上无需新增源码文件或修改 project.yml；若实际新增 Swift 文件，必须 `xcodegen generate` 并保留生成工程。

每项提交检查点先比较本轮快照。截图源文件当前仍未跟踪，不能对这些文件直接 `git add` 后把原有全部功能混进小修复提交；没有可分离、已授权的基线就保留本地改动及差异记录。具备可分离基线后使用各任务的中文提交说明，并追加 `Co-Authored-By: Codex <noreply@openai.com>`；不推送。

### Task 1: 一次 ESC 关闭当前截图

**Files:**
- Modify: `App/Screenshot/ImageEditor.swift` 的 `ImageEditor.body`、`dismiss()`、`toolOptions`、`ImageEditorCanvas`；同文件新增局部桥接。
- Test: `AppTests/ImageEditorTests.swift`。

**Interfaces:**
- Consumes: `ImageEditor.onClose: () -> Void`、`exporting: Bool`、`NSWindow.attachedSheet`。
- Produces: `ScreenshotEscapeView.handle(_ event: NSEvent) -> NSEvent?`、`stop()`，以及 `ScreenshotEscapeHandler(onEscape: () -> Void)`；不改变 ImageEditor initializer 或截图控制器的窗口关闭回调。

- [x] **Step 1: 添加窗口范围回归。** 在现有 `@MainActor` 测试套件内加入下面测试；不使用用户键盘或全局事件注入。

```swift
@Test func escapeIsScopedToEditorAndItsChildWindow() throws {
    let editor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                         styleMask: [.borderless], backing: .buffered, defer: false)
    let child = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                        styleMask: [.borderless], backing: .buffered, defer: false)
    for window in [editor, other, child] { window.isReleasedWhenClosed = false }
    let handler = ScreenshotEscapeView()
    var calls = 0
    handler.onEscape = { calls += 1 }
    editor.contentView = handler
    editor.addChildWindow(child, ordered: .above)
    defer {
        handler.stop(); editor.removeChildWindow(child)
        for window in [editor, other, child] { window.contentView = nil; window.close() }
    }
    func escape(_ window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    }
    #expect(handler.handle(try escape(editor)) == nil)
    #expect(handler.handle(try escape(child)) == nil)
    #expect(handler.handle(try escape(other)) != nil)
    #expect(calls == 2)
}
```

- [x] **Step 2: 先构建固定引擎，再跑红灯。**

```bash
bash scripts/build-engine.sh
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -only-testing:FastBudoTests/ImageEditorTests
```

预期新测试因 `ScreenshotEscapeView` 未定义失败。若引擎/工程错误，先解决环境，不把它当作行为红灯。

- [x] **Step 3: 在 ImageEditor.swift 增加局部桥接。**

```swift
struct ScreenshotEscapeHandler: NSViewRepresentable {
    let onEscape: () -> Void
    func makeNSView(context: Context) -> ScreenshotEscapeView {
        let view = ScreenshotEscapeView(); view.onEscape = onEscape; return view
    }
    func updateNSView(_ view: ScreenshotEscapeView, context: Context) { view.onEscape = onEscape }
    static func dismantleNSView(_ view: ScreenshotEscapeView, coordinator: ()) { view.stop() }
}

@MainActor final class ScreenshotEscapeView: NSView {
    var onEscape: () -> Void = {}
    private var monitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }
    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }
    func handle(_ event: NSEvent) -> NSEvent? {
        guard event.keyCode == 53,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let root = window, root.attachedSheet == nil else { return event }
        var target = event.window
        while let current = target {
            if current === root { onEscape(); return nil }
            target = current.parent
        }
        return event
    }
}
```

- [x] **Step 4: 统一关闭回调。** 当前 `dismiss()`、根 `.onExitCommand` 和工具面板 `.onExitCommand` 都改为调用 `closeEditor`，画布桥接的 onClose 也传此函数。X 按钮调用它；工具“完成”按钮继续只收起工具菜单。

```swift
private func closeEditor() {
    guard !exporting else { return }
    onClose()
}
```

在 ImageEditor 根视图 `.frame(minWidth: 240, minHeight: 120)` 后增加：

```swift
.background { ScreenshotEscapeHandler(onEscape: closeEditor).frame(width: 0, height: 0).accessibilityHidden(true) }
```

根视图与工具面板分别使用 `.onExitCommand(perform: closeEditor)`。删除因此不再使用的 `dismiss()`。局部监听遇到 attachedSheet 必须放行；保存取消保留图片。监听不能匹配设置页或 ShortcutRecorder 的 ESC。

- [x] **Step 5: 运行绿灯，并做焦点实测。** 运行 Step 2 的 ImageEditorTests。通过原生 UI 依次验证：画布 ESC 一次关图、工具弹层 ESC 一次关图、文字输入过程中 ESC 一次关图、保存面板 ESC 只取消保存、设置录入 ESC 不关闭截图、两个截图时只关闭当前图。使用合成图片；记录每种焦点的实际结果，不只检查源码。

- [x] **Step 6: 检查本轮差异并建立提交检查点。** `git diff --check`；具备可分离基线时提交 `修复截图在不同焦点下的ESC关闭行为`，追加规定署名，否则保留差异记录。

### Task 2: 截图直接复制，或弹出另存为对话框

**Files:**
- Modify: `App/Screenshot/ScreenshotController.swift` 的 initializer、`capture`、`captureEnded`、`stop`。
- Test: `AppTests/ScreenshotTests.swift`；保留 ImageEditorTests 的 Retina 和拒绝覆盖测试。

**Interfaces:**
- Consumes: `ImageEditorModel(image:)`、`png() async throws -> Data`、`save(to: URL) async throws`、`ScreenshotRegionSelector.copyToClipboard`。
- Produces: `CaptureAction: Equatable { edit, copy, download }`；`capture(_ mode: CaptureMode, action: CaptureAction = .edit)`；`deliver(_ image: NSImage, action: CaptureAction) async throws -> URL?`。
- initializer 新增 `pasteboard: NSPasteboard = .general`、`saveDestination: (@MainActor () async -> URL?)? = nil`。nil 使用真实保存面板，测试注入确认的 URL 或 nil；不新增下载目录依赖。
- 保存面板状态为 `private var quickSavePanel: NSSavePanel?`；`stop()` 负责取消真实面板。

- [x] **Step 1: 添加快速输出、取消及无覆盖测试。** 使用独立默认配置、剪贴板、临时目录及合成图：

```swift
@Test @MainActor func quickOutputsUseChosenURLsAndSkipEditor() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let board = NSPasteboard.withUniqueName()
    let name = "QuickScreenshotTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    var choices = [root.appendingPathComponent("first.png"), root.appendingPathComponent("second.png")]
    var prompts = 0
    let controller = ScreenshotController(defaults: defaults, pasteboard: board, saveDestination: {
        prompts += 1; return choices.removeFirst()
    })
    defer {
        controller.stop(); board.releaseGlobally(); defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: root)
    }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    memset(try #require(bitmap.bitmapData), 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
    let image = NSImage(size: NSSize(width: 40, height: 30)); image.addRepresentation(bitmap)
    let editors = NSApp.windows.filter { $0.title == "FastBudo 截图标注" }.count
    #expect(try await controller.deliver(image, action: .copy) == nil)
    #expect(prompts == 0)
    let copiedData = try #require(board.data(forType: .png))
    let copied = try #require(NSBitmapImageRep(data: copiedData))
    #expect(copied.pixelsWide == 80 && copied.pixelsHigh == 60)
    let changeCount = board.changeCount
    let first = try #require(try await controller.deliver(image, action: .download))
    let original = try Data(contentsOf: first)
    let second = try #require(try await controller.deliver(image, action: .download))
    #expect(prompts == 2 && first.lastPathComponent == "first.png" && second.lastPathComponent == "second.png")
    #expect(try Data(contentsOf: first) == original)
    #expect(try NSBitmapImageRep(data: Data(contentsOf: second))?.pixelsWide == 80)
    #expect(board.changeCount == changeCount)
    #expect(NSApp.windows.filter { $0.title == "FastBudo 截图标注" }.count == editors)
}

@Test @MainActor func cancelledSaveDoesNotWriteOrOverwrite() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    let target = root.appendingPathComponent("existing.png")
    let original = Data("keep".utf8); try original.write(to: target, options: .withoutOverwriting)
    let board = NSPasteboard.withUniqueName()
    board.setString("独立剪贴板", forType: .string)
    let count = board.changeCount
    let name = "QuickSaveCancel." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    var selected: URL?
    let controller = ScreenshotController(defaults: defaults, pasteboard: board, saveDestination: { selected })
    defer {
        controller.stop(); board.releaseGlobally(); defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: root)
    }
    let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
    memset(try #require(bitmap.bitmapData), 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
    let image = NSImage(size: NSSize(width: 4, height: 4)); image.addRepresentation(bitmap)
    let editors = NSApp.windows.filter { $0.title == "FastBudo 截图标注" }.count
    #expect(try await controller.deliver(image, action: .download) == nil)
    #expect(NSApp.windows.filter { $0.title == "FastBudo 截图标注" }.count == editors)
    selected = target
    await #expect(throws: (any Error).self) { try await controller.deliver(image, action: .download) }
    #expect(try Data(contentsOf: target) == original)
    #expect(board.changeCount == count)
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["existing.png"])
}

@Test func explicitDownloadIsNotChangedByControl() {
    #expect(CaptureAction.edit.effective(controlHeld: true) == .copy)
    #expect(CaptureAction.copy.effective(controlHeld: true) == .copy)
    #expect(CaptureAction.download.effective(controlHeld: true) == .download)
    #expect(CaptureAction.edit.effective(controlHeld: false) == .edit)
}
```

- [x] **Step 2: 跑红灯。**

```bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -only-testing:FastBudoTests/ScreenshotTests
```

预期缺少 CaptureAction、deliver 或 initializer 参数；不是引擎/工程环境失败。

- [x] **Step 3: 增加动作与依赖，保留原 initializer 调用兼容。** enum 放在同文件 CaptureMode 后。

```swift
enum CaptureAction: Equatable {
    case edit, copy, download
    func effective(controlHeld: Bool) -> Self { self == .edit && controlHeld ? .copy : self }
}
```

Controller 新增属性：

```swift
private let pasteboard: NSPasteboard
private let saveDestination: (@MainActor () async -> URL?)?
private var quickSavePanel: NSSavePanel?
```

initializer 在原参数后新增：

```swift
pasteboard: NSPasteboard = .general,
saveDestination: (@MainActor () async -> URL?)? = nil
```

在 super.init 前保存：

```swift
self.pasteboard = pasteboard
self.saveDestination = saveDestination
```

新增请求路径与输出方法：

```swift
private func requestQuickSaveURL() async -> URL? {
    guard !stopped else { return nil }
    let panel = NSSavePanel()
    quickSavePanel = panel
    panel.allowedContentTypes = [.png]
    panel.allowsOtherFileTypes = false
    panel.nameFieldStringValue = "截图-\(Int(Date().timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).png"
    panel.level = .floating
    return await withCheckedContinuation { continuation in
        NSApp.activate()
        panel.begin { [weak self] response in
            self?.quickSavePanel = nil
            continuation.resume(returning: response == .OK ? panel.url : nil)
        }
        panel.makeKeyAndOrderFront(nil)
    }
}

func deliver(_ image: NSImage, action: CaptureAction) async throws -> URL? {
    guard !stopped else { throw CancellationError() }
    let model = ImageEditorModel(image: image)
    switch action {
    case .edit:
        edit(image); message = "截图已打开，可标注、复制、保存或贴图。"; return nil
    case .copy:
        let png = try await model.png()
        guard !stopped else { throw CancellationError() }
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else { throw ClipError.invalid }
        message = "已复制截图"; return nil
    case .download:
        let selected: URL?
        if let saveDestination { selected = await saveDestination() }
        else { selected = await requestQuickSaveURL() }
        guard !stopped else { throw CancellationError() }
        guard let url = selected else { message = "已取消保存截图"; return nil }
        guard url.isFileURL else { throw ClipError.invalid }
        try await model.save(to: url)
        if !stopped { message = "已保存截图：\(url.lastPathComponent)" }
        return url
    }
}
```

在当前文件显式 `import UniformTypeIdentifiers`，让 `.png` 与 ImageEditor.swift 的类型导入一致。保存面板不依赖隐藏或非激活截图窗口，不调用 showSettings；必须实际验证 `NSApp.activate()` 与 makeKeyAndOrderFront 使面板可立即输入。原生保存面板取消只返回 nil，不能落入“输出失败”恢复编辑器路径。写盘复用 ImageEditorModel 的后台编码、`.withoutOverwriting`，不得因系统 Replace 确认而放开覆盖保护。

在 stop() 设置 stopped=true 后增加：

```swift
quickSavePanel?.cancel(nil)
```

真实面板关闭回调恢复 continuation 并清 quickSavePanel；不要清空引用却留下悬空等待，不把 stop 的 CancellationError 作为模态错误显示。测试注入的闭包只作立即返回的路径选择；停止面板等待的生命周期必须由真实面板探针核验。

- [x] **Step 4: 接通本次动作的不可变传递。** `capture` 保留原入口校验、350ms 延迟、选区/100ms 遮罩消失等待和超时；任务内部增加 `var selectedAction = action`。区域选择完成后：

```swift
selectedAction = action.effective(controlHeld: regionSelector?.copyToClipboard ?? false)
regionSelector = nil
```

区域路径删除追加 `-c` 的分支，让普通区域 Control 复制也先抓临时 PNG、校验像素，再经 deliver 写入。窗口截图仍保留系统自身 Control 操作及“无输出文件”分支。创建 terminationHandler 前冻结动作：

```swift
let outputAction = selectedAction
child.terminationHandler = { [weak self] process in
    let status = process.terminationStatus
    Task { @MainActor [weak self] in
        await self?.captureEnded(output: output, status: status, action: outputAction)
    }
}
```

把 captureEnded 签名改为 `private func captureEnded(output: URL, status: Int32, action: CaptureAction) async`。后台解码继续检查 20 MiB/像素；得到 NSImage 后替换原先直接 edit 的两行：

```swift
let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
do {
    try await deliver(result, action: action)
} catch {
    guard !stopped, !(error is CancellationError) else { return }
    edit(result)
    showError("截图输出失败，图片已保留，可重试：\(error.localizedDescription)")
}
```

解码的外层 catch 也必须先 guard !stopped && !(error is CancellationError)，避免 stop 清理临时目录导致读取失败后弹出新窗口。

保存面板等待、确认后的编码及写盘都保持 capturing=true；deliver 返回后外层 defer cleanupCapture 才清临时文件。不得提前清理、不得让下一次截图覆盖 action。保留最多两个编辑器的入口限制，使失败回退仍有容量。

- [x] **Step 5: 跑绿灯并实测原生保存面板。** 执行 ScreenshotTests 与 ImageEditorTests，保留 `saveNeverOverwritesExistingOutput`。原生探针验证：设置页关闭时从菜单发起快速下载，面板直接前置、Command+Shift+G 和文件名输入有效；确认得到实际 PNG 且无编辑器；Cancel/ESC 不写文件、不改剪贴板、不产生编辑器；面板等待时 stop 能结束等待；拒绝已有文件或无写权限时恢复截图供重试。失败路径只用专用临时文件或目录，不改用户文件权限。

- [x] **Step 6: 提交检查点。** `git diff --check`；具备可分离基线时提交 `增加截图直接复制和另存为输出路径` 并追加规定署名，否则保留本轮差异。

### Task 3: 快速入口、两个可选快捷键与完整验收

**Files:**
- Modify: `App/Screenshot/ScreenshotController.swift` 的 ShortcutAction、commit/configure/stop/recording。
- Modify: `App/Screenshot/ScreenshotSettings.swift`、`App/FastBudoApp.swift` 的 StatusPopover。
- Test: `AppTests/ShortcutRecorderTests.swift`、`AppTests/ScreenshotTests.swift`。
- Modify after implementation: `docs/guides/screenshot-pin.md`、`ARCHITECTURE.md`、`CHANGELOG.md`、`docs/README.md` 与本计划状态。

**Interfaces:**
- Consumes: Task 2 的 `capture(.region, action: .copy/.download)`；现有 `RecordedShortcut`、`ShortcutRecorder`、`ClipboardHotKey.register/stop/matches`。
- Produces: `ShortcutAction: CaseIterable { capture, paste, copy, download }`；`shortcut(for:) -> RecordedShortcut?`；`clearShortcut(for:)`；现有 commitShortcut 签名不变。

- [x] **Step 1: 增加默认、冲突和事件隔离红灯测试。** 每个测试使用 UUID UserDefaults suite 并 defer 删除，controller.stop 释放临时注册。首先加入不会占系统组合的冲突用例：

```swift
@Test @MainActor func quickShortcutsStartUnassignedAndRejectExistingCapture() throws {
    let name = "QuickShortcutTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.set(1, forKey: "screenshotKey")
    defaults.set(Int(controlKey | shiftKey), forKey: "screenshotModifiers")
    let controller = ScreenshotController(defaults: defaults)
    defer { controller.stop(); defaults.removePersistentDomain(forName: name) }
    #expect(controller.shortcut(for: .copy) == nil)
    #expect(controller.shortcut(for: .download) == nil)
    let duplicate = RecordedShortcut(key: 1, modifiers: UInt32(controlKey | shiftKey), label: "⌃⇧S")
    #expect(!controller.commitShortcut(duplicate, for: .copy))
    #expect(!controller.commitShortcut(duplicate, for: .download))
    #expect(defaults.object(forKey: "screenshotCopyKey") == nil)
    #expect(defaults.object(forKey: "screenshotDownloadKey") == nil)
}

@Test @MainActor func fiveHotKeyIdentifiersStayIsolated() {
    let keys = (UInt32(1)...5).map { ClipboardHotKey(identifier: $0) }
    defer { keys.forEach { $0.stop() } }
    for id in UInt32(1)...5 {
        let event = EventHotKeyID(signature: 0x46424350, id: id)
        for (index, key) in keys.enumerated() { #expect(key.matches(event) == (index + 1 == Int(id))) }
    }
}
```

- [x] **Step 2: 跑红灯。**

```bash
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode -only-testing:FastBudoTests/ShortcutRecorderTests
```

- [x] **Step 3: 把两种旧动作扩展为四种，统一偏好和注册查找。** 保留原两个 ClipboardHotKey 对象，再添加 identifier 4、5；以 switch 返回对应实例，不另建注册框架。

```swift
enum ShortcutAction: CaseIterable {
    case capture, paste, copy, download
    var prefix: String {
        switch self {
        case .capture: "screenshot"
        case .paste: "pin"
        case .copy: "screenshotCopy"
        case .download: "screenshotDownload"
        }
    }
    var title: String {
        switch self {
        case .capture: "截图"
        case .paste: "贴图"
        case .copy: "截图并复制"
        case .download: "截图并下载"
        }
    }
}
private let copyKey = ClipboardHotKey(identifier: 4)
private let downloadKey = ClipboardHotKey(identifier: 5)
private func hotKey(for action: ShortcutAction) -> ClipboardHotKey {
    switch action {
    case .capture: snipKey
    case .paste: pasteKey
    case .copy: copyKey
    case .download: downloadKey
    }
}
func shortcut(for action: ShortcutAction) -> RecordedShortcut? {
    let prefix = action.prefix
    let fallbackKey: Int? = action == .capture ? 1 : action == .paste ? 35 : nil
    guard let key = defaults.object(forKey: prefix + "Key") as? Int ?? fallbackKey else { return nil }
    let modifiers = defaults.object(forKey: prefix + "Modifiers") as? Int ?? Int(controlKey | shiftKey)
    let name = [1: "S", 35: "P", 8: "C", 9: "V", 49: "空格"][key] ?? "按键 \(key)"
    let label = defaults.string(forKey: prefix + "KeyLabel")
        ?? RecordedShortcut.modifierLabel(UInt32(clamping: modifiers)) + name
    return RecordedShortcut(key: UInt32(clamping: key), modifiers: UInt32(clamping: modifiers), label: label)
}
```

用下面完整函数替换原 commitShortcut，避免残留旧 prefix/other 或旧单对单 guard；保留原有错误字段和提示：

```swift
func commitShortcut(_ shortcut: RecordedShortcut, for action: ShortcutAction) -> Bool {
    guard ClipboardHotKey.accepts(key: shortcut.key, modifiers: shortcut.modifiers) else { return false }
    for other in ShortcutAction.allCases where other != action {
        if let value = self.shortcut(for: other), value.key == shortcut.key, value.modifiers == shortcut.modifiers {
            shortcutError = "组合与本应用其他快捷键冲突，原设置已保留"
            shortcutMessage = shortcutError ?? ""; return false
        }
    }
    let clipEnabled = defaults.object(forKey: "clipHotKeyEnabled") as? Bool ?? true
    let clipKey = defaults.object(forKey: "clipHotKeyCode") as? Int ?? 9
    let clipModifiers = defaults.object(forKey: "clipHotKeyModifiers") as? Int ?? Int(controlKey | shiftKey)
    guard !(clipEnabled && Int(shortcut.key) == clipKey && Int(shortcut.modifiers) == clipModifiers) else {
        shortcutError = "组合与本应用其他快捷键冲突，原设置已保留"
        shortcutMessage = shortcutError ?? ""; return false
    }
    let target = hotKey(for: action)
    guard target.register(key: shortcut.key, modifiers: shortcut.modifiers) else {
        shortcutError = "快捷键已被占用或系统不支持，原设置已保留"
        shortcutMessage = shortcutError ?? ""; return false
    }
    shortcutError = nil
    let prefix = action.prefix
    defaults.set(Int(shortcut.key), forKey: prefix + "Key")
    defaults.set(Int(shortcut.modifiers), forKey: prefix + "Modifiers")
    defaults.set(shortcut.label, forKey: prefix + "KeyLabel")
    if recordingShortcut || !(defaults.object(forKey: "screenshotHotKeysEnabled") as? Bool ?? true) { target.stop() }
    return true
}
```

添加清除：

```swift
func clearShortcut(for action: ShortcutAction) {
    guard action == .copy || action == .download else { return }
    hotKey(for: action).stop()
    for suffix in ["Key", "Modifiers", "KeyLabel"] { defaults.removeObject(forKey: action.prefix + suffix) }
    shortcutError = nil
    configureShortcuts()
}
```

configureShortcuts 完整替换为以下流程，保留各旧状态文字：

```swift
func configureShortcuts() {
    guard !recordingShortcut && !stopped else { return }
    guard defaults.object(forKey: "screenshotHotKeysEnabled") as? Bool ?? true else {
        ShortcutAction.allCases.forEach { hotKey(for: $0).stop() }
        shortcutMessage = shortcutError ?? "截图与贴图快捷键已关闭"; return
    }
    var states: [String] = []
    for action in ShortcutAction.allCases {
        let key = hotKey(for: action)
        key.action = { [weak self] in
            guard let self else { return }
            switch action {
            case .capture: self.capture(.region)
            case .paste: self.paste()
            case .copy: self.capture(.region, action: .copy)
            case .download: self.capture(.region, action: .download)
            }
        }
        guard let value = shortcut(for: action) else {
            key.stop(); states.append(action.title + "：未设置"); continue
        }
        let success = key.register(key: value.key, modifiers: value.modifiers)
        states.append(action.title + (success ? "：已注册" : "：不可用或冲突"))
    }
    shortcutMessage = shortcutError ?? states.joined(separator: "；")
}
```

`setShortcutRecording(true)` 和 `stop()` 中原来的 `snipKey.stop(); pasteKey.stop()` 替换为 `ShortcutAction.allCases.forEach { hotKey(for: $0).stop() }`；不改已经暂停/恢复剪贴板快捷键的 shortcutRecordingChanged 回调。搜索整个文件的 snipKey/pasteKey 引用，保证没有遗漏的仅停两种动作路径。

- [x] **Step 4: 增加入口并接现有录入器。** StatusPopover 的“截图”菜单和 ScreenshotSettings 的截图分组各加入：

```swift
Button("截图并复制") { screenshot.capture(.region, action: .copy) }
Button("截图并下载") { screenshot.capture(.region, action: .download) }
```

设置页的变量名使用 `controller`；两个按钮另起一行，不把五个按钮塞进已有 HStack。繁忙时随现有 `.disabled(controller.capturing)` 禁用。提示固定为：`选完区域直接复制，或弹出另存为对话框保存 PNG，不打开标注编辑器。`

ScreenshotSettings 新增两个标签偏好，保留旧 snipLabel/pinLabel；把已有 shortcut helper 的参数收敛为 `shortcut(_ title: String, label: String, action: ScreenshotController.ShortcutAction)`。已有四个仅供旧 helper 使用的 key/modifiers @AppStorage 可删除，未再使用 Carbon 时删除该文件 import Carbon：

```swift
@AppStorage("screenshotCopyKeyLabel") private var copyLabel = ""
@AppStorage("screenshotDownloadKeyLabel") private var downloadLabel = ""
```

四个调用分别传 `snipLabel/.capture`、`pinLabel/.paste`、`copyLabel/.copy`、`downloadLabel/.download`。helper 实现：

```swift
HStack {
    Text(title).frame(width: 100, alignment: .leading)
    ShortcutRecorder(display: label.isEmpty ? controller.shortcut(for: action)?.label ?? "未设置" : label,
        onRecordingChanged: controller.setShortcutRecording,
        onCommit: { controller.commitShortcut($0, for: action) })
        .frame(width: 260, height: 28)
    if action == .copy || action == .download {
        Button("清除") { controller.clearShortcut(for: action) }
            .disabled(controller.shortcut(for: action) == nil)
    }
}
```

在 560pt 设置窗口实际查看布局；行宽不足时将录入器改成 `.frame(maxWidth: .infinity).frame(height: 28)`，不扩大窗口或挤掉清除按钮。颜色、分组容器继续用现有 SettingsSection/SettingsToggle。

- [x] **Step 5: 新增清除/兼容测试并跑绿灯。** 用 UserDefaults 预置 `screenshotCopyKey/Modifiers/KeyLabel` 和原截图/贴图各三项，记录旧字典，调用 `clearShortcut(for: .copy)`；断言复制三项消失、原六项逐字节保留、`.download` 仍未设置。总开关设 false 避免默认注册。沿用现有 registrationFailurePreservesOldBinding 的 F18/F19 专用组合回归，验证新动作候选被占用时旧偏好/旧注册保留，不使用用户真实组合。执行 Step 2 和 ScreenshotTests。

清除/兼容回归的实际测试为：

```swift
@Test @MainActor func clearingQuickBindingPreservesExistingPreferences() throws {
    let name = "QuickShortcutClear." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.set(false, forKey: "screenshotHotKeysEnabled")
    for (prefix, key, label) in [("screenshot", 1, "⌃⇧S"), ("pin", 35, "⌃⇧P"), ("screenshotCopy", 8, "⌃⌥C")] {
        defaults.set(key, forKey: prefix + "Key")
        defaults.set(Int(controlKey | shiftKey), forKey: prefix + "Modifiers")
        defaults.set(label, forKey: prefix + "KeyLabel")
    }
    let old = ["screenshot", "pin"].flatMap { prefix in ["Key", "Modifiers", "KeyLabel"].map { prefix + $0 } }
    let values = old.map { defaults.object(forKey: $0) as? NSObject }
    let controller = ScreenshotController(defaults: defaults)
    defer { controller.stop(); defaults.removePersistentDomain(forName: name) }
    controller.clearShortcut(for: .copy)
    for suffix in ["Key", "Modifiers", "KeyLabel"] { #expect(defaults.object(forKey: "screenshotCopy" + suffix) == nil) }
    for (key, value) in zip(old, values) { #expect((defaults.object(forKey: key) as? NSObject) == value) }
    #expect(controller.shortcut(for: .download) == nil)
}
```

- [x] **Step 6: 按顺序执行完整门禁。** 不并行跑真实焦点回归与 Release 构建。

```bash
bash scripts/build-engine.sh
xcodebuild test -scheme FastBudo -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode
python3 -m unittest discover -s Tests/ClipboardLifecycle -v
xcodebuild -scheme FastBudo -configuration Release -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/xcode build
python3 "$HOME/.codex/skills/ai-project-standards/scripts/validate-project-standards.py" --root .
python3 scripts/check-private-paths.py
git diff --check
```

文档完成后重跑文档门禁和相对链接检查。没有修改归档/桥接/文件复制路径，本次不额外跑 Bridge/Performance；不能因此宣称这些专项通过。若之后修改这些路径，再补相应专项。

- [x] **Step 7: 做原生探针验收并更新实际记录。** 使用独立 bundle/defaults/clipboard/临时保存目录及合成图：菜单复制、菜单下载、两个新快捷键、取消无副作用、另存为确认路径、Cancel/ESC 无文件、连续两次不同保存文件、失败恢复图、输入焦点下 ESC、保存面板 ESC、快捷键清除与重启保留。核对文件实际像素/方向及 UI 不产生编辑器，而非只查看状态文案。Control 直接复制要使用独立剪贴板依赖的探针，不覆盖用户剪贴板。多屏混合缩放未实测时明确记录未测。

指南写“已完成”的内容必须有本步证据；架构记录 action 随任务传递、局部 ESC 范围及四种截图/贴图快捷键；CHANGELOG 写未发布条目；文档索引保留设计/计划成对入口。本计划任务仍未执行前不得勾选或冒充通过。

- [x] **Step 8: 提交检查点和交付。** 复核本轮快照差异；具备可分离基线时提交 `增加快速截图入口与独立快捷键` 并追加规定署名。没有新的安装/推送/发布授权时保留工作区，不重启用户应用。安装若另获授权，先检查未保存图片和任务、固定身份签名、产物隐私扫描、同卷备份替换及启动核验，不覆盖运行中的应用。

## 自审与交接

- ESC 画布、工具、文字输入及模态例外：Task 1。
- 无编辑器复制、另存为面板、用户选择路径、像素、无覆盖、取消与失败恢复：Task 2。
- 菜单、设置、独立可选快捷键、旧偏好、五入口隔离、完整实机验收：Task 3。
- CaptureAction、deliver、快捷键名称及偏好后缀在任务间一致；无新增后台服务或全局 ESC 注册。
- 用户已选择 subagent-driven-development；代码检查进度以各任务复选框及执行台账为准，真实焦点验收在最终整合阶段完成。


## 本轮执行结果

2026-10-27：三个任务的规格和代码质量复核通过，最终整体审查通过。固定引擎构建成功；116 项应用测试通过；ClipboardLifecycle 独立回归通过（冷启动、设置关闭、已有设置窗口三场景）；Release 构建通过。未提交现有截图 WIP，不安装、合并、推送或发布。

独立合成图探针验证一次 ESC 在画布、工具弹层和真实文字输入焦点下关图；保存 sheet ESC 只取消；两张图只关闭当前图；设置录入 ESC 保留截图。快速复制仅写独立剪贴板；快速另存为立即响应 Command+Shift+G，确认得到 1440×880 PNG，ESC取消无新输出。真实面板等待中 stop 会取消并释放；输出被已有文件阻挡后，原字节保持且截图恢复到编辑器。两个新绑定实际录入/清除并重启保留，560pt设置窗布局已查看。

探针调用公共输出方法和合成捕获完成回调，不申请新的屏幕录制权限，不替代真实屏幕授权、多屏混合缩放及完整快捷键抓图端到端验收。已确认的编码/写盘事务不支持中途取消；stop仅抑制后续反馈，文件仍可能完成。后台解码中stop的窄竞态未稳定复现，相关错误分支有停止门禁且通过代码审查。任务检查点在现有WIP基线下以差异包保留，未作混合提交。
