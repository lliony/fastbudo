import AppKit

/// 自己处理区域选择，避免系统交互截图强制使用十字指针。
@MainActor final class ScreenshotRegionSelector {
    private var window: NSPanel?
    private var timeout: Task<Void, Never>?
    private var completion: ((CGRect?) -> Void)?
    private(set) var copyToClipboard = false
    private(set) var selectedFrame: CGRect?

    init(completion: @escaping (CGRect?) -> Void) { self.completion = completion }

    func show() {
        guard completion != nil, window == nil, let primary = NSScreen.screens.first else { cancel(); return }
        let desktop = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        let panel = PinnedImagePanel(contentRect: desktop, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "FastBudo 区域选取"
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let view = RegionSelectionView(frame: CGRect(origin: .zero, size: desktop.size)) { [weak self] selection, copy in
            self?.copyToClipboard = copy
            let capture = selection.flatMap { Self.captureRect($0, desktop: desktop, primaryTop: primary.frame.maxY) }
            self?.selectedFrame = capture.map {
                CGRect(x: $0.minX, y: primary.frame.maxY - $0.maxY, width: $0.width, height: $0.height)
            }
            self?.finish(capture)
        }
        panel.contentView = view; window = panel
        panel.orderFrontRegardless(); panel.makeKey(); panel.makeFirstResponder(view)
        NSCursor.arrow.set()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            self?.cancel()
        }
    }

    func cancel() { finish(nil); closePanel() }

    // 转交后清理选区任务不能再关闭编辑器持有的面板。
    func takeEditorPanel() -> NSPanel? {
        guard completion == nil, selectedFrame != nil else { return nil }
        let panel = window
        window = nil
        return panel
    }

    private func closePanel() {
        window?.orderOut(nil); window?.contentView = nil; window?.close(); window = nil
    }

    private func finish(_ rect: CGRect?) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel(); timeout = nil
        if rect == nil { closePanel() } else { window?.orderOut(nil) }
        completion(rect)
    }

    /// AppKit 以左下为原点，系统截图以主屏左上为原点；保留点坐标，由系统处理 Retina 缩放。
    nonisolated static func captureRect(_ selection: CGRect, desktop: CGRect, primaryTop: CGFloat) -> CGRect? {
        let rect = selection.standardized.intersection(desktop)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        return CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height).integral
    }
}

@MainActor private final class RegionSelectionView: NSView {
    private var start: CGPoint?
    private var selection: CGRect?
    private let completion: (CGRect?, Bool) -> Void

    init(frame: CGRect, completion: @escaping (CGRect?, Bool) -> Void) {
        self.completion = completion
        super.init(frame: frame)
        setAccessibilityLabel("区域截图：拖动选择，Escape 取消")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func mouseDown(with event: NSEvent) { start = window?.convertPoint(toScreen: event.locationInWindow); selection = nil; needsDisplay = true }
    override func mouseDragged(with event: NSEvent) {
        guard let start, let window else { return }
        let end = window.convertPoint(toScreen: event.locationInWindow)
        selection = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) { mouseDragged(with: event); completion(selection, event.modifierFlags.contains(.control)) }
    override func rightMouseDown(with event: NSEvent) { completion(nil, false) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { completion(nil, false) } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        var local: CGRect?
        if let selection, let window {
            let rect = selection.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
            local = rect; shade.appendRect(rect)
        }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.18).setFill(); shade.fill()
        if let local {
            NSColor.systemRed.setStroke()
            let border = NSBezierPath(rect: local); border.lineWidth = 1; border.stroke()
        } else {
            let message = "拖动选择区域 · Escape 取消"
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
            let size = (message as NSString).size(withAttributes: attributes)
            (message as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY), withAttributes: attributes)
        }
    }
}
