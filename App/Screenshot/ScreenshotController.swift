import AppKit
import SwiftUI
import Carbon
import UniformTypeIdentifiers

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
            // 等菜单收起和快捷键松开，避免把浮窗或按下的修饰键带入系统截图。
            do { try await Task.sleep(for: .milliseconds(350)) } catch { self.capturing = false; return }
            guard !stopped else { capturing = false; return }
            do {
                var arguments = mode.arguments
                var selectedAction = action
                if case .region = mode {
                    let rect: CGRect? = await withCheckedContinuation { continuation in
                        let selector = ScreenshotRegionSelector { continuation.resume(returning: $0) }
                        regionSelector = selector; selector.show()
                    }
                    selectedAction = action.effective(controlHeld: regionSelector?.copyToClipboard ?? false)
                    regionSelector = nil
                    guard let rect, !stopped else { capturing = false; message = "截图已取消。"; return }
                    arguments = ["-R", "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))"]
                    // 等选区遮罩从窗口合成器移除，避免把遮罩一起截入图片。
                    try await Task.sleep(for: .milliseconds(100))
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
                child.terminationHandler = { [weak self] process in
                    let status = process.terminationStatus
                    Task { @MainActor [weak self] in await self?.captureEnded(output: output, status: status, action: outputAction) }
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

    private func captureEnded(output: URL, status: Int32, action: CaptureAction) async {
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
                _ = try await deliver(result, action: action)
            } catch {
                guard !stopped, !(error is CancellationError) else { return }
                edit(result)
                showError("截图输出失败，图片已保留，可重试：\(error.localizedDescription)")
            }
        } catch {
            guard !stopped, !(error is CancellationError) else { return }
            showError("无法读取截图：\(error.localizedDescription)")
        }
    }

    private func cleanupCapture() {
        if let root = captureDirectory { try? FileManager.default.removeItem(at: root) }
        captureDirectory = nil; process = nil; capturing = false; captureTask = nil
    }

    nonisolated static func editorFrame(imageSize: CGSize, visibleFrame: CGRect, scale: CGFloat) -> CGRect {
        let available = visibleFrame.insetBy(dx: 16, dy: 16)
        let width = max(1, imageSize.width), height = max(1, imageSize.height)
        let factor = min(1 / max(1, scale), min(available.width / width, available.height / height))
        let size = CGSize(width: min(available.width, max(240, width * factor)),
                          height: min(available.height, max(120, height * factor)))
        return CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    func edit(_ image: NSImage) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let frame = Self.editorFrame(imageSize: image.size, visibleFrame: screen.visibleFrame, scale: screen.backingScaleFactor)
        let window = PinnedImagePanel(contentRect: frame,
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "FastBudo 截图标注"
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.delegate = self
        window.contentView = NSHostingView(rootView: ImageEditor(image: image, window: window,
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
        pin.panel.delegate = self
        pins.append(pin)
        pin.panel.orderFrontRegardless()
        message = "已贴到屏幕；拖动标题栏移动，菜单栏可恢复隐藏或穿透的贴图。"
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
        // HostingView 持有模型，关闭时断开模型→面板→视图的循环。
        window.contentView = nil
        pins.removeAll { $0.panel === window }
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
