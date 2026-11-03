import AppKit
import SwiftUI
import ImageIO

enum ScreenshotImage {
    /// 先读元数据再解码，防止小压缩文件展开成无界图片。
    static func decode(_ data: Data) throws -> CGImage {
        guard data.count <= ClipPayload.maximum else { throw ClipError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 20000, height <= 20000,
              width * height <= 40_000_000 else { throw ClipError.tooLarge }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height)
        ] as CFDictionary) else { throw ClipError.invalid }
        return image
    }

    static func transformed(_ image: CGImage, turns: Int, horizontal: Bool, vertical: Bool) -> CGImage? {
        let turns = ((turns % 4) + 4) % 4
        let width = turns % 2 == 0 ? image.width : image.height
        let height = turns % 2 == 0 ? image.height : image.width
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.scaleBy(x: horizontal ? -1 : 1, y: vertical ? -1 : 1)
        context.rotate(by: CGFloat(turns) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2,
                                      width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()
    }
}

/// 非激活面板让贴图保持可见，不拉出设置窗口或切换前台应用。
@MainActor final class PinnedImagePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class PinnedImageDragSurface: NSView {
    private var dragStart: (cursor: CGPoint, windowOrigin: CGPoint)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStart = (window.convertPoint(toScreen: event.locationInWindow), window.frame.origin)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let dragStart else { return }
        let cursor = window.convertPoint(toScreen: event.locationInWindow)
        window.setFrameOrigin(CGPoint(
            x: dragStart.windowOrigin.x + cursor.x - dragStart.cursor.x,
            y: dragStart.windowOrigin.y + cursor.y - dragStart.cursor.y
        ))
    }

    override func mouseUp(with event: NSEvent) { dragStart = nil }
}

private struct PinnedImageDragSurfaceView: NSViewRepresentable {
    func makeNSView(context: Context) -> PinnedImageDragSurface { PinnedImageDragSurface() }
    func updateNSView(_ nsView: PinnedImageDragSurface, context: Context) {}
}

enum PinnedImageAction: CaseIterable, Hashable {
    case zoomOut
    case zoomIn
    case rotateCounterclockwise
    case rotateClockwise
    case flipHorizontal
    case flipVertical
    case opacity
    case copy

    var title: String {
        switch self {
        case .zoomOut: "缩小"
        case .zoomIn: "放大"
        case .rotateCounterclockwise: "逆时针旋转"
        case .rotateClockwise: "顺时针旋转"
        case .flipHorizontal: "水平翻转"
        case .flipVertical: "垂直翻转"
        case .opacity: "透明度"
        case .copy: "复制图片"
        }
    }

    var systemImage: String {
        switch self {
        case .zoomOut: "minus.magnifyingglass"
        case .zoomIn: "plus.magnifyingglass"
        case .rotateCounterclockwise: "rotate.left"
        case .rotateClockwise: "rotate.right"
        case .flipHorizontal: "arrow.left.and.right"
        case .flipVertical: "arrow.up.and.down"
        case .opacity: "circle.lefthalf.filled"
        case .copy: "doc.on.doc"
        }
    }
}

enum PinnedImageActionEffect: Equatable {
    case none
    case showOpacity
}

struct PinnedImageToolbarLayout {
    private static let buttonWidth: CGFloat = 28
    private static let spacing: CGFloat = 4
    private static let horizontalPadding: CGFloat = 8
    private static let retentionPriority: [PinnedImageAction] = [
        .zoomOut, .zoomIn, .copy, .opacity,
        .rotateCounterclockwise, .rotateClockwise,
        .flipHorizontal, .flipVertical
    ]

    static func split(availableWidth: CGFloat) -> (visible: [PinnedImageAction], overflow: [PinnedImageAction]) {
        let actions = PinnedImageAction.allCases
        guard availableWidth > 0 else { return ([], actions) }
        let fullWidth = horizontalPadding * 2
            + CGFloat(actions.count) * buttonWidth
            + CGFloat(actions.count - 1) * spacing
        guard availableWidth < fullWidth else { return (actions, []) }

        let contentWidth = max(0, availableWidth - horizontalPadding * 2)
        let totalSlots = max(0, Int((contentWidth + spacing) / (buttonWidth + spacing)))
        let visibleCount = max(0, totalSlots - 1)
        let selected = Set(retentionPriority.prefix(visibleCount))
        return (actions.filter(selected.contains), actions.filter { !selected.contains($0) })
    }
}

@MainActor @Observable final class PinnedImage: NSObject, NSWindowDelegate {
    let id = UUID()
    let original: CGImage
    let panel: PinnedImagePanel
    var image: CGImage
    var turns = 0
    var horizontal = false
    var vertical = false
    var opacity = 1.0 { didSet { panel.alphaValue = opacity } }
    var clickThrough = false { didSet { panel.ignoresMouseEvents = clickThrough } }
    private(set) var zoom = 1.0
    /// 面板关闭后通知持有者移除引用；断环与关闭语义都在本模块内完成。
    var onClosed: (() -> Void)?
    private let pasteboard: NSPasteboard

    init(image: CGImage, pasteboard: NSPasteboard = .general) {
        self.original = image; self.image = image
        self.pasteboard = pasteboard
        panel = PinnedImagePanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
                                backing: .buffered, defer: false)
        super.init()
        panel.title = "FastBudo 贴图"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 240, height: 160)
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: PinnedImageView(model: self))
        resize(factor: 1)
        panel.center()
    }

    func close() { panel.close() }

    func windowWillClose(_ notification: Notification) {
        // HostingView 持有模型，这里断开模型→面板→视图的循环。
        panel.contentView = nil
        onClosed?()
    }

    func transform() {
        if let result = ScreenshotImage.transformed(original, turns: turns, horizontal: horizontal, vertical: vertical) {
            image = result; resize(factor: 1)
        } else { NSSound.beep() }
    }

    func rotate(_ direction: Int) {
        // 单轴镜像改变旋转的手性，按当前画面的视觉方向旋转。
        turns += direction * (horizontal != vertical ? -1 : 1)
        transform()
    }

    func resize(factor: Double) {
        zoom = min(4, max(0.1, zoom * factor))
        let available = panel.screen?.visibleFrame.size ?? NSScreen.main?.visibleFrame.size ?? NSSize(width: 1000, height: 800)
        let fit = min(1, min((available.width - 80) / CGFloat(image.width), (available.height - 120) / CGFloat(image.height)))
        let width = min(available.width, max(240, CGFloat(image.width) * fit * zoom))
        let height = min(available.height - 40, max(160, CGFloat(image.height) * fit * zoom + 44))
        panel.setContentSize(NSSize(width: width, height: height))
    }

    func copyToPasteboard() {
        let value = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        pasteboard.clearContents()
        pasteboard.writeObjects([value])
    }

    func perform(_ action: PinnedImageAction) -> PinnedImageActionEffect {
        switch action {
        case .zoomOut:
            resize(factor: 0.8)
        case .zoomIn:
            resize(factor: 1.25)
        case .rotateCounterclockwise:
            rotate(1)
        case .rotateClockwise:
            rotate(-1)
        case .flipHorizontal:
            horizontal.toggle(); transform()
        case .flipVertical:
            vertical.toggle(); transform()
        case .opacity:
            return .showOpacity
        case .copy:
            copyToPasteboard()
        }
        return .none
    }

    func isActive(_ action: PinnedImageAction) -> Bool {
        switch action {
        case .flipHorizontal: horizontal
        case .flipVertical: vertical
        case .opacity: opacity < 1
        default: false
        }
    }
}

private struct PinnedImageView: View {
    @Bindable var model: PinnedImage
    @State private var showingOpacity = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                let layout = PinnedImageToolbarLayout.split(availableWidth: geometry.size.width)
                HStack(spacing: 4) {
                    ForEach(layout.visible, id: \.self) { action in
                        actionButton(action)
                    }
                    if !layout.overflow.isEmpty {
                        Menu {
                            ForEach(layout.overflow, id: \.self) { action in
                                Button { handle(action) } label: {
                                    Label(action.title, systemImage: action.systemImage)
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("更多")
                        .accessibilityLabel("更多贴图操作")
                    }
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .popover(isPresented: $showingOpacity) {
                    Slider(value: $model.opacity, in: 0.15...1)
                        .frame(width: 180)
                        .padding()
                        .help("透明度")
                        .accessibilityLabel("贴图透明度")
                }
            }
            .frame(height: 44)
            Image(decorative: model.image, scale: 1).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { PinnedImageDragSurfaceView() }
                .accessibilityLabel("置顶图片，可拖动图片移动")
        }.background(Color(nsColor: .windowBackgroundColor))
            .onKeyPress(.escape) { model.close(); return .handled }
    }

    private func actionButton(_ action: PinnedImageAction) -> some View {
        let active = model.isActive(action) || (action == .opacity && showingOpacity)
        return Button { handle(action) } label: {
            Image(systemName: action.systemImage)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .background(active ? Color.accentColor.opacity(0.2) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    if active {
                        RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(action.title)
        .accessibilityLabel(action.title)
    }

    private func handle(_ action: PinnedImageAction) {
        if model.perform(action) == .showOpacity { showingOpacity = true }
    }
}
