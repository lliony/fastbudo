import AppKit

/// 选区完成的几何与动作；面板所有权另行转交，避免 AppKit 对象跨隔离传递。
struct RegionSelection: Sendable {
    let captureRect: CGRect
    let screenFrame: CGRect
    let copyToClipboard: Bool
}

/// 屏幕坐标与系统截图坐标的换算口径，三处翻转共用同一实现。
enum CaptureGeometry {
    /// AppKit 全局屏幕坐标（左下原点）→ 系统截图坐标（主屏左上原点）。
    static func captureRect(_ selection: CGRect, desktop: CGRect, primaryTop: CGFloat) -> CGRect? {
        let rect = selection.standardized.intersection(desktop)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1 else { return nil }
        return CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height).integral
    }

    /// 系统截图坐标 → AppKit 全局屏幕坐标。
    static func screenFrame(_ capture: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: capture.minX, y: primaryTop - capture.maxY, width: capture.width, height: capture.height)
    }

    /// 全局屏幕坐标 → 以 windowFrame 为参照的翻转局部坐标。
    static func flippedLocal(_ screen: CGRect, in windowFrame: CGRect) -> CGRect {
        CGRect(x: screen.minX - windowFrame.minX, y: windowFrame.maxY - screen.maxY,
               width: screen.width, height: screen.height)
    }
}

/// 自己处理区域选择，避免系统交互截图强制使用十字指针。
@MainActor final class ScreenshotRegionSelector {
    private var window: NSPanel?
    private var timeout: Task<Void, Never>?
    private var completion: ((RegionSelection?) -> Void)?
    /// 成功后由调用方在主线程接管面板并复用为编辑器窗口。
    private var transferredPanel: NSPanel?

    init(completion: @escaping (RegionSelection?) -> Void) { self.completion = completion }

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
            guard let self else { return }
            guard let selection,
                  let capture = CaptureGeometry.captureRect(selection, desktop: desktop, primaryTop: primary.frame.maxY) else {
                self.finish(nil); return
            }
            let transferred = self.window
            self.window = nil
            transferred?.orderOut(nil)
            self.transferredPanel = transferred
            self.finish(RegionSelection(captureRect: capture,
                                        screenFrame: CaptureGeometry.screenFrame(capture, primaryTop: primary.frame.maxY),
                                        copyToClipboard: copy))
        }
        panel.contentView = view; window = panel
        panel.orderFrontRegardless(); panel.makeKey(); panel.makeFirstResponder(view)
        NSCursor.arrow.set()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            self?.cancel()
        }
    }

    /// 成功后 completion 已消费，再次取消不会关闭已转交给编辑器的面板。
    func cancel() { finish(nil) }

    /// 取走已转交的面板；重复调用返回 nil。
    func takeTransferredPanel() -> NSPanel? {
        defer { transferredPanel = nil }
        return transferredPanel
    }

    private func closePanel() {
        window?.orderOut(nil); window?.contentView = nil; window?.close(); window = nil
    }

    private func finish(_ result: RegionSelection?) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel(); timeout = nil
        if result == nil { closePanel() }
        completion(result)
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
