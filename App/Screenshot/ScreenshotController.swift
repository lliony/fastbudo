import AppKit
import SwiftUI
import Carbon
import UniformTypeIdentifiers
import ScreenCaptureKit

enum CaptureMode {
    case region, window, screen(Int)
    var arguments: [String] {
        switch self {
        case .region: []
        case .window: ["-i", "-w", "-o"]
        case .screen(let number): ["-D", String(max(1, number))]
        }
    }
}

/// 屏幕对应的 CGDirectDisplayID，供 ScreenCaptureKit 抓帧与按屏取冻结帧使用。
extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return number.uint32Value
    }
}

enum CaptureAction: Equatable {
    case edit, copy, download
    func effective(controlHeld: Bool) -> Self { self == .edit && controlHeld ? .copy : self }
}

@MainActor @Observable final class ScreenshotController: NSObject, NSWindowDelegate {
    var message = "截图仅在本机处理；贴图关闭或退出后释放。"
    var shortcutMessage = ""
    private(set) var capturing = false
    private(set) var pins: [PinnedImage] = []
    private var editors: [NSWindow] = []
    private let snipKey = ClipboardHotKey(identifier: 2)
    private let pasteKey = ClipboardHotKey(identifier: 3)
    private var captureTask: Task<Void, Never>?
    private var process: Process?
    private var regionSelector: ScreenshotRegionSelector?
    private var pendingEditorPanel: NSPanel?
    private var captureDirectory: URL?
    private var timedOut = false
    private var stopped = false
    private var decoding = false
    private let defaults: UserDefaults
    private let pasteboard: NSPasteboard
    private let saveDestination: (@MainActor () async -> URL?)?
    private var quickSavePanel: NSSavePanel?

    private(set) var screenCaptureAuthorized = false
    private let screenCaptureAccess: () -> Bool
    private var recordingShortcut = false
    private var shortcutError: String?
    var shortcutRecordingChanged: (Bool) -> Void = { _ in }

    init(defaults: UserDefaults = .standard,
         screenCaptureAccess: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         pasteboard: NSPasteboard = .general,
         saveDestination: (@MainActor () async -> URL?)? = nil) {
        self.defaults = defaults; self.screenCaptureAccess = screenCaptureAccess
        self.pasteboard = pasteboard; self.saveDestination = saveDestination
        super.init()
    }

    func refreshScreenCapturePermission() { screenCaptureAuthorized = screenCaptureAccess() }

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
    func setShortcutRecording(_ active: Bool) {
        guard recordingShortcut != active else { return }
        recordingShortcut = active
        if active { shortcutError = nil }
        if active { ShortcutAction.allCases.forEach { hotKey(for: $0).stop() } }
        shortcutRecordingChanged(active)
        if !active && !stopped { configureShortcuts() }
    }

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

    func clearShortcut(for action: ShortcutAction) {
        guard action == .copy || action == .download else { return }
        hotKey(for: action).stop()
        for suffix in ["Key", "Modifiers", "KeyLabel"] { defaults.removeObject(forKey: action.prefix + suffix) }
        shortcutError = nil
        configureShortcuts()
    }

    func start() { stopped = false; configureShortcuts() }

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

    func capture(_ mode: CaptureMode, action: CaptureAction = .edit) {
        guard !capturing else { return }
        guard editors.count < 2 else { showError("请先关闭一个截图编辑窗口（最多同时两个）。"); return }
        refreshScreenCapturePermission()
        if !screenCaptureAuthorized { CGRequestScreenCaptureAccess(); refreshScreenCapturePermission() }
        guard screenCaptureAuthorized else {
            showError("请在系统设置 → 隐私与安全性 → 屏幕与系统音频录制中允许 FastBudo，再重新截图；系统可能要求重启应用。")
            return
        }
        capturing = true; timedOut = false
        message = "截图中：拖动选择区域或点击窗口，Escape 取消。"
        captureTask = Task { [weak self] in
            guard let self else { return }
            switch mode {
            case .region, .screen: break
            case .window:
                // 系统窗口选取仍需等菜单收起和修饰键松开；区域/全屏走冻结帧，无需等待。
                do { try await Task.sleep(for: .milliseconds(350)) } catch { self.capturing = false; return }
            }
            guard !stopped else { capturing = false; return }
            do {
                var arguments = mode.arguments
                var selectedAction = action
                var region: RegionSelection?
                let screens = NSScreen.screens
                let desktop = screens.reduce(CGRect.null) { $0.union($1.frame) }
                let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first
                let primaryTop = primary?.frame.maxY ?? 0
                if case .window = mode {
                    // 窗口截图仍走系统交互，无需冻结帧。
                } else if case .region = mode {
                    // 先在弹遮罩前冻结桌面帧（ScreenCaptureKit 一次性抓帧）：若不先抓，遮罩会进入抓帧而污染出图。
                    // 抓帧读取窗口服务器、不激活本应用，正在显示的右键菜单/浮窗保持原样，冻结帧既是背景（所见即所得）也是出图来源。
                    let frozenFrames = await freezeScreens()
                    region = await withCheckedContinuation { continuation in
                        let selector = ScreenshotRegionSelector { continuation.resume(returning: $0) }
                        selector.frozenFrames = frozenFrames
                        regionSelector = selector
                        selector.show()
                    }
                    pendingEditorPanel = regionSelector?.takeTransferredPanel()
                    selectedAction = action.effective(controlHeld: region?.copyToClipboard ?? false)
                    guard let rect = region?.captureRect, !stopped else { cleanupCapture(); message = "截图已取消。"; return }
                    if let cropped = cropFrozen(region: rect, desktop: desktop, primaryTop: primaryTop, screens: screens, frozenFrames: frozenFrames) {
                        await finishCapturedImage(cropped, region: region, action: selectedAction)
                        cleanupCapture()
                        return
                    }
                    // 冻结帧不可用（选区跨屏/所在屏无帧/无录制权限）时回退系统 `-R` 抓取。
                    arguments = ["-R", "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"]
                    // 等选区遮罩从窗口合成器移除，避免把遮罩一起截入图片。
                    try await Task.sleep(for: .milliseconds(100))
                } else if case .screen(let number) = mode {
                    // 全屏截图只需目标屏单帧，按显示器只抓该屏，避免把其余各屏整帧一并驻留（多 4K 屏峰值数百 MB）。
                    let target = screens.indices.contains(number - 1) ? screens[number - 1] : nil
                    if let id = target?.displayID,
                       let frozen = await freezeScreens(restrictedTo: [id])[id] {
                        await finishCapturedImage(frozen, region: nil, action: selectedAction)
                        cleanupCapture()
                        return
                    }
                    // 冻结帧不含该显示器或无权限时回退系统 `-D` 抓取。
                }
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("fastbudo-capture-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                captureDirectory = root
                let output = root.appendingPathComponent("capture.png")
                let child = Process()
                child.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                child.arguments = ["-x", "-t", "png"] + arguments + [output.path]
                child.standardInput = FileHandle.nullDevice
                child.standardOutput = FileHandle.nullDevice
                child.standardError = FileHandle.nullDevice
                let outputAction = selectedAction
                let outputRegion = region
                child.terminationHandler = { [weak self] process in
                    let status = process.terminationStatus
                    Task { @MainActor [weak self] in
                        await self?.captureEnded(output: output, status: status, action: outputAction, region: outputRegion)
                    }
                }
                process = child
                try child.run()
                do { try await Task.sleep(for: .seconds(120)) } catch { return }
                if child.isRunning { timedOut = true; child.terminate() }
            } catch {
                cleanupCapture()
                guard !stopped, !(error is CancellationError) else { return }
                showError("无法截图：\(error.localizedDescription)")
            }
        }
    }

    private func captureEnded(output: URL, status: Int32, action: CaptureAction, region: RegionSelection?) async {
        captureTask?.cancel()
        defer { cleanupCapture() }
        guard !stopped else { return }
        if timedOut { showError("截图等待超时，已取消。请重新发起截图。"); return }
        guard FileManager.default.fileExists(atPath: output.path) else {
            message = status == 0 || status == 1 ? "截图已取消，或已通过系统 Control 操作直接复制。" : "截图失败，请检查屏幕录制权限后重试。"
            if status != 0 && status != 1 { showError(message) }
            return
        }
        guard status == 0 else { showError("截图未成功完成，请重试。"); return }
        do {
            let image = try await Task.detached(priority: .userInitiated) {
                let values = try output.resourceValues(forKeys: [.fileSizeKey])
                guard let size = values.fileSize, size <= ClipPayload.maximum else { throw ClipError.tooLarge }
                return try ScreenshotImage.decode(Data(contentsOf: output, options: .mappedIfSafe))
            }.value
            guard !stopped else { return }
            let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            do {
                if action == .edit { editCapturedImage(result, region: region) }
                else { _ = try await deliver(result, action: action) }
            } catch {
                guard !stopped, !(error is CancellationError) else { return }
                editCapturedImage(result, region: region)
                showError("截图输出失败，图片已保留，可重试：\(error.localizedDescription)")
            }
        } catch {
            guard !stopped, !(error is CancellationError) else { return }
            showError("无法读取截图：\(error.localizedDescription)")
        }
    }

    /// 直接把已就绪的截图分发到编辑或快速输出，等同 `captureEnded` 解码后的收尾路径。
    private func finishCapturedImage(_ image: CGImage, region: RegionSelection?, action: CaptureAction) async {
        let result = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        do {
            if action == .edit { editCapturedImage(result, region: region) }
            else { _ = try await deliver(result, action: action) }
        } catch {
            guard !stopped, !(error is CancellationError) else { return }
            editCapturedImage(result, region: region)
            showError("截图输出失败，图片已保留，可重试：\(error.localizedDescription)")
        }
    }

    /// 触发瞬间按显示器异步冻结桌面帧（ScreenCaptureKit 一次性抓帧）：不激活本应用、不收起正在显示的右键菜单/浮窗提示。
/// 区域/全屏截图以此为背景与出图来源；窗口截图仍走系统交互，无需冻结。无录制权限或抓帧失败时返回空字典，由调用方回退系统抓取。
/// 指定 `restrictedTo` 时只抓这些显示器（全屏截图只取目标屏），避免把其余各屏整帧一并驻留。
private func freezeScreens(restrictedTo: Set<CGDirectDisplayID>? = nil) async -> [CGDirectDisplayID: CGImage] {
    guard let content = try? await SCShareableContent.current else { return [:] }
    var frames: [CGDirectDisplayID: CGImage] = [:]
    for display in content.displays where restrictedTo == nil || restrictedTo!.contains(display.displayID) {
        // 每个显示器单独配置并按原生像素宽高抓帧；共用配置或留默认宽高会让副屏帧尺寸与屏幕不匹配，
        // 造成背景/裁剪比例错位与留白（多显示器尤其明显）。
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.width = display.width
        config.height = display.height
        guard let image = try? await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(display: display, excludingWindows: []),
            configuration: config) else { continue }
        frames[display.displayID] = image
    }
    return frames
}

/// 把「显示器抓取坐标（主屏左上原点）」的选区换算为该屏像素矩形；选区越出该屏图像返 nil。
nonisolated static func pixelRect(_ capture: CGRect, inDisplay origin: CGPoint, scale: CGFloat, imageSize: CGSize) -> CGRect? {
    guard scale > 0 else { return nil }
    let px = CGRect(x: (capture.minX - origin.x) * scale, y: (capture.minY - origin.y) * scale,
                    width: capture.width * scale, height: capture.height * scale).integral
    guard px.minX >= 0, px.minY >= 0, px.maxX <= imageSize.width, px.maxY <= imageSize.height else { return nil }
    return px
}

/// 取选区所在显示器的冻结帧并裁剪；选区跨屏或显示器无帧时返回 nil，由调用方回退系统抓取。
@MainActor
private func cropFrozen(region capture: CGRect, desktop: CGRect, primaryTop: CGFloat, screens: [NSScreen], frozenFrames: [CGDirectDisplayID: CGImage]) -> CGImage? {
    for screen in screens {
        guard let origin = CaptureGeometry.captureRect(screen.frame, desktop: desktop, primaryTop: primaryTop) else { continue }
        guard origin.contains(capture), let id = screen.displayID, let frozen = frozenFrames[id] else { continue }
        let scale = CGFloat(frozen.width) / max(1, screen.frame.width)
        guard let px = Self.pixelRect(capture, inDisplay: origin.origin, scale: scale,
                                      imageSize: CGSize(width: frozen.width, height: frozen.height)) else { continue }
        return frozen.cropping(to: px)
    }
    return nil
}

private func editCapturedImage(_ image: NSImage, region: RegionSelection?) {
        if let region, let panel = pendingEditorPanel {
            pendingEditorPanel = nil
            edit(image, in: panel, selectionFrame: region.screenFrame)
            message = "可在原选区标注、复制、保存或贴图。"
        } else {
            edit(image)
            message = "截图已打开，可标注、复制、保存或贴图。"
        }
    }

    private func cleanupCapture() {
        regionSelector?.cancel(); regionSelector = nil
        // 已转交但未用于编辑的面板需要在这里释放，避免隐藏面板继续持有视图。
        if let panel = pendingEditorPanel { panel.contentView = nil; panel.close() }
        pendingEditorPanel = nil
        if let root = captureDirectory { try? FileManager.default.removeItem(at: root) }
        captureDirectory = nil; process = nil; capturing = false; captureTask = nil
    }

    nonisolated static func editorFrame(imageSize: CGSize, visibleFrame: CGRect, scale: CGFloat) -> CGRect {
        let available = visibleFrame.insetBy(dx: 16, dy: 16)
        let width = max(1, imageSize.width), height = max(1, imageSize.height)
        let limit = min(available.width / width, available.height / height)
        let base = min(1 / max(1, scale), limit)
        let baseSize = CGSize(width: width * base, height: height * base)
        // 已满足最小编辑区就保持 1:1 或屏幕上限；不足时才整体等比放大，避免宽高分别钳制。
        if baseSize.width < 240 || baseSize.height < 120 {
            let minimum = max(240 / width, 120 / height)
            if width * minimum <= available.width, height * minimum <= available.height {
                let factor = min(max(base, minimum), limit)
                let size = CGSize(width: width * factor, height: height * factor)
                return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                              width: size.width, height: size.height)
            }
            // 极端比例无法同时满足最小编辑区和屏幕约束，保留旧的分别钳制兜底。
            let size = CGSize(width: min(available.width, max(240, baseSize.width)),
                              height: min(available.height, max(120, baseSize.height)))
            return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                          width: size.width, height: size.height)
        }
        return CGRect(x: available.midX - baseSize.width / 2, y: available.midY - baseSize.height / 2,
                      width: baseSize.width, height: baseSize.height)
    }

    func edit(_ image: NSImage, in existingWindow: NSWindow? = nil, selectionFrame: CGRect? = nil) {
        let screens = NSScreen.screens
        let selectedScreen = selectionFrame.flatMap { selection in
            screens.max { left, right in
                let a = selection.intersection(left.visibleFrame), b = selection.intersection(right.visibleFrame)
                return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
            }
        }
        guard let screen = selectedScreen ?? screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let contentFrame = selectionFrame.map { _ in existingWindow?.frame ?? screens.reduce(CGRect.null) { $0.union($1.frame) } }
            ?? Self.editorFrame(imageSize: image.size, visibleFrame: screen.visibleFrame, scale: screen.backingScaleFactor)
        let frame: CGRect
        if selectionFrame == nil {
            // 独立浮窗为图片下方预留工具条，工具不再压在截图上。
            let compact = EditorLayout.usesCompactControls(in: CGRect(origin: .zero, size: contentFrame.size))
            let toolbar = EditorLayout.toolbarSize(compact: compact)
            let visible = screen.visibleFrame
            let width = min(max(contentFrame.width, toolbar.width) + EditorLayout.inset * 2, visible.width)
            let height = min(contentFrame.height + toolbar.height + EditorLayout.inset * 3, visible.height)
            frame = CGRect(x: visible.midX - width / 2, y: visible.midY - height / 2, width: width, height: height)
        } else {
            frame = contentFrame
        }
        let window = existingWindow ?? PinnedImagePanel(contentRect: frame,
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.setFrame(frame, display: false)
        window.title = "FastBudo 截图标注"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = selectionFrame == nil
        window.level = .floating
        window.delegate = self
        let canvasFrame = selectionFrame.map {
            CaptureGeometry.flippedLocal($0, in: frame)
        } ?? CGRect(x: (frame.width - contentFrame.width) / 2, y: EditorLayout.inset,
                     width: contentFrame.width, height: contentFrame.height)
        window.contentView = NSHostingView(rootView: ImageEditor(image: image, window: window,
            canvasFrame: canvasFrame, inline: selectionFrame != nil,
            onPin: { [weak self] in self?.pin($0) }, onClose: { [weak window] in window?.close() }))
        editors.append(window)
        window.orderFrontRegardless(); window.makeKey()
    }

    func pin(_ image: NSImage) {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let pixels = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { showError("图片无法解码。"); return }
        pin(pixels)
    }

    func pin(_ image: CGImage) {
        let total = pins.reduce(0) { $0 + $1.original.width * $1.original.height }
        guard Self.canPin(width: image.width, height: image.height, count: pins.count, existingPixels: total) else {
            showError("贴图已达到上限（10 张或合计四千万像素），请先关闭部分贴图。"); return
        }
        let pin = PinnedImage(image: image)
        pin.onClosed = { [weak self, weak pin] in
            guard let self, let pin else { return }
            pins.removeAll { $0 === pin }
        }
        pins.append(pin)
        pin.panel.orderFrontRegardless()
        message = "已贴到屏幕；拖动图片移动，菜单栏可恢复隐藏或穿透的贴图。"
    }

    nonisolated static func canPin(width: Int, height: Int, count: Int, existingPixels: Int) -> Bool {
        width > 0 && height > 0 && width <= 20000 && height <= 20000 && count < 10 &&
            existingPixels >= 0 && width * height <= 40_000_000 - existingPixels
    }

    func paste() {
        do {
            guard let payload = try ClipboardCapture.read(.general, includeOwnWrites: true), payload.kind == .image else {
                showError("剪贴板中没有可用图片，请先复制图片或从剪贴板历史选择“贴到屏幕”。"); return
            }
            guard let data = payload.items.lazy.compactMap({ $0["public.png"] ?? $0["public.tiff"] }).first else { throw ClipError.invalid }
            pinData(data)
        } catch { showError(error.localizedDescription) }
    }

    func pinData(_ data: Data) {
        guard !decoding else { return }
        guard pins.count < 10, pins.reduce(0, { $0 + $1.original.width * $1.original.height }) < 40_000_000 else {
            showError("贴图已达到上限，请先关闭部分贴图。"); return
        }
        decoding = true
        Task {
            defer { decoding = false }
            do {
                let image = try await Task.detached(priority: .userInitiated) { try ScreenshotImage.decode(data) }.value
                guard !stopped else { return }
                pin(image)
            } catch { showError(error.localizedDescription) }
        }
    }

    func togglePins() {
        let hide = pins.contains { $0.panel.isVisible }
        for pin in pins {
            if hide { pin.panel.orderOut(nil) } else { pin.panel.orderFrontRegardless() }
        }
    }

    func restorePins() {
        for pin in pins { pin.clickThrough = false; pin.opacity = 1; pin.panel.orderFrontRegardless() }
    }

    func closePins() { for pin in pins { pin.panel.close() } }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // 贴图面板在 PinnedImage 内自行断环；这里只处理编辑器窗口。
        window.contentView = nil
        editors.removeAll { $0 === window }
    }

    func showError(_ text: String) {
        message = text
        let alert = NSAlert(); alert.messageText = "截图与贴图"; alert.informativeText = text
        alert.runModal()
    }

    func stop() {
        stopped = true
        quickSavePanel?.cancel(nil)
        setShortcutRecording(false)
        ShortcutAction.allCases.forEach { hotKey(for: $0).stop() }; regionSelector?.cancel(); captureTask?.cancel()
        if let process, process.isRunning { process.terminate() }
        cleanupCapture()
        closePins()
        for window in editors { window.close() }
    }
}
