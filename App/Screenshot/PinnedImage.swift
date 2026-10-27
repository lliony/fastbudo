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

@MainActor @Observable final class PinnedImage {
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

    init(image: CGImage) {
        self.original = image; self.image = image
        panel = PinnedImagePanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
                                styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
                                backing: .buffered, defer: false)
        panel.title = "FastBudo 贴图"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 240, height: 160)
        panel.contentView = NSHostingView(rootView: PinnedImageView(model: self))
        resize(factor: 1)
        panel.center()
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

    func copy() {
        let value = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([value])
    }
}

private struct PinnedImageView: View {
    @Bindable var model: PinnedImage
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.resize(factor: 0.8) } label: { Image(systemName: "minus.magnifyingglass") }.help("缩小")
                Button { model.resize(factor: 1.25) } label: { Image(systemName: "plus.magnifyingglass") }.help("放大")
                Menu("操作") {
                    Button("逆时针旋转") { model.rotate(1) }
                    Button("顺时针旋转") { model.rotate(-1) }
                    Button("水平翻转") { model.horizontal.toggle(); model.transform() }
                    Button("垂直翻转") { model.vertical.toggle(); model.transform() }
                    Button("复制图片", action: model.copy)
                    Divider()
                    Button("鼠标穿透（从菜单栏恢复）") { model.clickThrough = true }
                    Button("隐藏贴图（从菜单栏恢复）") { model.panel.orderOut(nil) }
                    Button("关闭贴图") { model.panel.close() }
                }.fixedSize()
                Slider(value: $model.opacity, in: 0.15...1).frame(minWidth: 50).help("透明度").accessibilityLabel("贴图透明度")
            }.padding(8)
            Image(decorative: model.image, scale: 1).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("置顶图片，可拖动标题栏移动")
        }.background(Color(nsColor: .windowBackgroundColor))
            .onKeyPress(.escape) { model.panel.orderOut(nil); return .handled }
    }
}
