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
/// 每块屏幕各建一个遮罩窗口：显示器使用独立 Space 时，单个跨屏窗口只归属其中一块屏，副屏将无法选区。
@MainActor final class ScreenshotRegionSelector {
    private var windows: [NSPanel] = []
    private var activePanel: NSPanel?
    private var timeout: Task<Void, Never>?
    private var completion: ((RegionSelection?) -> Void)?
    /// 成功后由调用方在主线程接管面板并复用为编辑器窗口。
    private var transferredPanel: NSPanel?
    private var desktop: CGRect = .null
    private var primaryTop: CGFloat = 0
    /// 触发瞬间各显示器的冻结帧（displayID→CGImage）；对应屏有帧时作为选区背景（所见即所得），否则透明穿透实时画面。
    var frozenFrames: [CGDirectDisplayID: CGImage] = [:]

    init(completion: @escaping (RegionSelection?) -> Void) { self.completion = completion }

    func show() {
        guard completion != nil, windows.isEmpty else { cancel(); return }
        let screens = NSScreen.screens
        guard let primary = screens.first(where: { $0.frame.origin == .zero }) ?? screens.first else { cancel(); return }
        desktop = screens.reduce(CGRect.null) { $0.union($1.frame) }
        primaryTop = primary.frame.maxY

        for screen in screens {
            let panel = PinnedImagePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "FastBudo 区域选取"
            panel.isReleasedWhenClosed = false
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = RegionSelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.screenFrame = screen.frame
            view.showsHint = screen.frame.origin == .zero
            view.frozenImage = screen.displayID.flatMap { frozenFrames[$0] }
            view.onSelection = { [weak self] selection in
                self?.activePanel = panel
                self?.apply(selection)
            }
            view.onFinish = { [weak self] selection, copy in
                self?.activePanel = panel
                self?.complete(selection, copyToClipboard: copy)
            }
            panel.contentView = view
            windows.append(panel)
        }

        let front = windows.first
        windows.forEach { $0.orderFrontRegardless() }
        front?.makeKey()
        if let view = front?.contentView { front?.makeFirstResponder(view) }
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

    /// 所有遮罩共用同一选区，拖动跨屏时各屏都显示同一条框。
    private func apply(_ selection: CGRect?) {
        for panel in windows {
            (panel.contentView as? RegionSelectionView)?.globalSelection = selection
        }
    }

    private func complete(_ selection: CGRect?, copyToClipboard: Bool) {
        guard completion != nil else { return }
        guard let panel = activePanel ?? windows.first,
              let selection,
              let capture = CaptureGeometry.captureRect(selection, desktop: desktop, primaryTop: primaryTop) else {
            finish(nil); return
        }
        // 选区跨多屏时编辑窗口需要覆盖这些屏；单屏内保持该屏大小，与内联编辑一致。
        let union = NSScreen.screens
            .filter { $0.frame.intersects(selection) }
            .reduce(CGRect.null) { $0.union($1.frame) }
        transferredPanel = panel
        for other in windows where other !== panel {
            other.contentView = nil
            other.close()
        }
        windows.removeAll()
        activePanel = nil
        panel.orderOut(nil)
        if !union.isNull, union != panel.frame { panel.setFrame(union, display: false) }
        finish(RegionSelection(captureRect: capture,
                               screenFrame: CaptureGeometry.screenFrame(capture, primaryTop: primaryTop),
                               copyToClipboard: copyToClipboard))
    }

    private func closePanels() {
        for panel in windows {
            panel.contentView = nil
            panel.orderOut(nil)
            panel.close()
        }
        windows.removeAll()
        activePanel = nil
    }

    private func finish(_ result: RegionSelection?) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel(); timeout = nil
        if result == nil { closePanels() }
        completion(result)
    }
}

@MainActor private final class RegionSelectionView: NSView {
    var screenFrame: CGRect = .zero
    var showsHint = false
    var frozenImage: CGImage?
    var globalSelection: CGRect? {
        didSet { needsDisplay = true }
    }
    var onSelection: ((CGRect?) -> Void)?
    var onFinish: ((CGRect?, Bool) -> Void)?
    private var start: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setAccessibilityLabel("区域截图：拖动选择，Escape 取消")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    /// 遮罩非激活面板，首次点击也要直接开始选区而不是只做激活。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        start = window?.convertPoint(toScreen: event.locationInWindow)
        onSelection?(nil)
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start, let window else { return }
        let end = window.convertPoint(toScreen: event.locationInWindow)
        onSelection?(CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                            width: abs(end.x - start.x), height: abs(end.y - start.y)))
    }
    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        onFinish?(globalSelection, event.modifierFlags.contains(.control))
    }
    override func rightMouseDown(with event: NSEvent) { onFinish?(nil, false) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil, false) } else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let frozenImage { drawFrozenBackground(frozenImage) }
        let shade = NSBezierPath(rect: bounds)
        var local: CGRect?
        if let globalSelection {
            let clipped = globalSelection.intersection(screenFrame)
            if !clipped.isNull, clipped.width > 0, clipped.height > 0 {
                let rect = clipped.offsetBy(dx: -screenFrame.minX, dy: -screenFrame.minY)
                local = rect; shade.appendRect(rect)
            }
        }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.18).setFill(); shade.fill()
        if let local {
            NSColor.systemRed.setStroke()
            let border = NSBezierPath(rect: local); border.lineWidth = 1; border.stroke()
        } else if showsHint {
            let message = "拖动选择区域 · Escape 取消"
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.white]
            let size = (message as NSString).size(withAttributes: attributes)
            (message as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY), withAttributes: attributes)
        }
    }

    /// 把本显示器冻结帧绘制为背景（本就是该屏内容，无需切片），选区遮罩叠加在上方形成“明亮/灰显”。
    /// 直接用 `cgContext.draw` 绘制即可——它是该屏居顶像素，绘制到非翻转视图时会按 CG 图像语义正确放置，
    /// 不再需要手动 Y 翻转（整图翻转会把整屏上下颠倒）。
    private func drawFrozenBackground(_ frozen: CGImage) {
        guard frozen.width > 0, frozen.height > 0 else { return }
        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.draw(frozen, in: CGRect(origin: .zero, size: bounds.size))
    }
}
