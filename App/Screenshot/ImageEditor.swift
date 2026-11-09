import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ImageIO

enum AnnotationTool: String, CaseIterable {
    case rectangle = "矩形", ellipse = "椭圆", arrow = "箭头", pen = "画笔", text = "文字", mosaic = "马赛克"

    var symbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .arrow: "arrow.up.right"
        case .pen: "pencil.tip"
        case .text: "textformat"
        case .mosaic: "square.grid.3x3.fill"
        }
    }
}

struct ImageAnnotation {
    var tool: AnnotationTool
    var points: [CGPoint]
    var color: NSColor = .systemRed
    var width: CGFloat = 4
    var text = ""
    /// 文字标注的显示边框开关与宽度；默认无边框（透明背景），开启时按该宽度描边。
    var hasBorder = false
    var borderWidth: CGFloat = 1

    var rect: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                      width: abs(last.x - first.x), height: abs(last.y - first.y))
    }

    /// 仅对文字标注返回可在原图像素坐标使用的盒子矩形（宽高≥2），供画布选中高亮引用。
    var textAnnotatedRect: CGRect? {
        guard tool == .text else { return nil }
        let box = rect
        return box.width >= 2 && box.height >= 2 ? box : nil
    }
}

/// 编辑器几何口径：SwiftUI 工具层和 AppKit 画布共用，避免两套坐标。
enum EditorLayout {
    /// 工具条与窗口边缘的最小距离。
    static let inset: CGFloat = 8
    /// 工具条可见边缘与图片边缘的间距；贴角但不与图片像素粘连。
    static let gap: CGFloat = 2
    static let regularSize = CGSize(width: 296, height: 72)
    static let compactSize = CGSize(width: 152, height: 92)

    /// 在给定矩形内等比完整显示图片；不做 1:1 限制，极小图会放大到可用区域。
    static func imageRect(in bounds: CGRect, imageSize: CGSize) -> CGRect {
        guard bounds.width > 0, bounds.height > 0,
              imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    static func usesCompactControls(in imageRect: CGRect) -> Bool {
        imageRect.width < regularSize.width || imageRect.height < regularSize.height
    }

    /// 工具条外框尺寸，含四周贴边留白；锚点计算与视图尺寸共用同一口径。
    static func toolbarSize(compact: Bool) -> CGSize {
        let size = compact ? compactSize : regularSize
        return CGSize(width: size.width + gap * 2, height: size.height + gap * 2)
    }

    /// 工具条锚点与对齐：下方外侧贴图片下缘，上方/重叠时贴图片上/下缘，始终右对齐图片。
    struct ToolbarPlacement {
        var origin: CGPoint
        var alignment: Alignment
    }

    /// 优先贴在图片下方外侧；下方放不下就翻到上方，仍放不下才重叠进图片右下角。
    static func toolbarPlacement(imageRect: CGRect, toolbarSize: CGSize, in bounds: CGRect) -> ToolbarPlacement {
        // 水平只夹到窗口边缘，让工具条能真正贴住图片右缘。
        let x = min(max(imageRect.maxX - toolbarSize.width, bounds.minX),
                    max(bounds.minX, bounds.maxX - toolbarSize.width))
        let below = CGPoint(x: x, y: imageRect.maxY)
        if below.y + toolbarSize.height <= bounds.maxY - inset {
            return ToolbarPlacement(origin: below, alignment: .topTrailing)
        }
        let above = CGPoint(x: x, y: imageRect.minY - toolbarSize.height)
        if above.y >= bounds.minY + inset {
            return ToolbarPlacement(origin: above, alignment: .bottomTrailing)
        }
        return ToolbarPlacement(origin: CGPoint(x: x, y: imageRect.maxY - toolbarSize.height),
                                alignment: .bottomTrailing)
    }
}

/// 标注保留原图像素坐标，预览缩放不改变最终导出尺寸。
@MainActor @Observable final class ImageEditorModel {
    let source: CGImage?
    var tool = AnnotationTool.rectangle
    var color = Color.red
    var width = 4.0
    /// 新建文字标注时的默认边框开关与宽度；提交时快照进标注。
    var textBorderEnabled = false
    var textBorderWidth = 1.0
    /// 标注开关与工具选择合并，避免“选工具”和“进入标注”互相等待。
    var isAnnotating = false
    var message = "选择工具后在图片上拖动；文字工具在点击处添加文字。"
    private(set) var annotations: [ImageAnnotation] = []
    private(set) var undone: [ImageAnnotation] = []
    private(set) var revision = 0
    private var renderCache: (revision: Int, image: NSImage)?

    init(image: NSImage) {
        var rect = CGRect(origin: .zero, size: image.size)
        source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    var size: CGSize { CGSize(width: source?.width ?? 1, height: source?.height ?? 1) }

    func select(_ tool: AnnotationTool) {
        self.tool = tool
        isAnnotating = true
    }

    func append(_ annotation: ImageAnnotation) {
        guard annotations.count < 200 else { message = "标注已达 200 条，请先撤销部分内容。"; return }
        annotations.append(annotation); undone.removeAll(); revision += 1
    }

    func undo() {
        guard let last = annotations.popLast() else { return }
        undone.append(last); revision += 1
    }

    func redo() {
        guard let last = undone.popLast() else { return }
        annotations.append(last); revision += 1
    }

    /// 移动第 `index` 条标注整体（文字盒子用）。
    func translate(_ index: Int, by offset: CGSize) {
        guard annotations.indices.contains(index) else { return }
        annotations[index].points = annotations[index].points.map {
            CGPoint(x: $0.x + offset.width, y: $0.y + offset.height)
        }
        undone.removeAll(); revision += 1
    }

    /// 把第 `index` 条文字标注的盒子改为 `box`（并规范为左上/右下两点）。
    func setTextSize(at index: Int, box: CGRect) {
        guard annotations.indices.contains(index) else { return }
        let standardized = box.standardized
        annotations[index].points = [
            CGPoint(x: standardized.minX, y: standardized.minY),
            CGPoint(x: standardized.maxX, y: standardized.maxY),
        ]
        undone.removeAll(); revision += 1
    }

    /// 原影像素坐标下的完整渲染；同一 revision 的画布预览、复制、保存与贴图共用一份结果。
    func rendered() throws -> NSImage {
        if let renderCache, renderCache.revision == revision { return renderCache.image }
        guard let source,
              let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ClipError.invalid }
        context.translateBy(x: 0, y: CGFloat(source.height)); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        draw(pending: nil)
        guard let result = context.makeImage() else { throw ClipError.invalid }
        let image = NSImage(cgImage: result, size: size)
        renderCache = (revision, image)
        return image
    }

    private func renderedPixels() throws -> CGImage {
        // 无已完成标注时源图即最终像素，直接返回编码：跳过 rendered() 对同样分辨率再做一次全量重绘。
        if annotations.isEmpty, let source { return source }
        let image = try rendered()
        var rect = CGRect(origin: .zero, size: size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw ClipError.invalid }
        return cg
    }

    /// 把「源图 + 已完成标注」渲染到指定像素分辨率，供交互期画布当底图。
    /// 拖动标注每帧 revision++；按显示尺寸直接渲染，避免为一次预览生成全分辨率位图（导出走 `rendered()`）。
    func preview(pixels: CGSize, pointSize: CGSize) throws -> NSImage {
        guard pixels.width > 0, pixels.height > 0, let source,
              let context = CGContext(data: nil, width: Int(pixels.width.rounded()), height: Int(pixels.height.rounded()),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ClipError.invalid }
        // 与画布 drawOverlay 同口径：按显示尺寸对两轴分别缩放并翻转，标注坐标仍用源像素单位。
        context.translateBy(x: 0, y: pixels.height)
        context.scaleBy(x: pixels.width / CGFloat(source.width), y: -(pixels.height / CGFloat(source.height)))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        draw(pending: nil)
        guard let cg = context.makeImage() else { throw ClipError.invalid }
        return NSImage(cgImage: cg, size: pointSize)
    }

    nonisolated private static func encode(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ClipError.invalid }
        CGImageDestinationAddImage(output, image, nil)
        guard CGImageDestinationFinalize(output) else { throw ClipError.invalid }
        return data as Data
    }

    func png() async throws -> Data {
        let image = try renderedPixels()
        return try await Task.detached(priority: .userInitiated) { try Self.encode(image) }.value
    }

    func save(to url: URL) async throws {
        let image = try renderedPixels()
        // 编码与磁盘写入不占用 AppKit 事件线程，慢盘不会冻结整个应用。
        try await Task.detached(priority: .userInitiated) {
            try Self.encode(image).write(to: url, options: .withoutOverwriting)
        }.value
    }

    func draw(pending: ImageAnnotation?) {
        guard let source else { return }
        NSImage(cgImage: source, size: size).draw(in: CGRect(origin: .zero, size: size), from: .zero,
                                               operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        for annotation in annotations { draw(annotation: annotation) }
        if let pending { draw(annotation: pending) }
    }

    func draw(annotation mark: ImageAnnotation) {
        guard let first = mark.points.first, let last = mark.points.last else { return }
        mark.color.setStroke(); mark.color.setFill()
        let path = NSBezierPath(); path.lineWidth = mark.width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        switch mark.tool {
        case .rectangle: path.appendRect(mark.rect)
        case .ellipse: path.appendOval(in: mark.rect)
        case .pen:
            path.move(to: first)
            for point in mark.points.dropFirst() { path.line(to: point) }
            if mark.points.count == 1 { path.line(to: CGPoint(x: first.x + 0.1, y: first.y)) }
        case .arrow:
            path.move(to: first); path.line(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x), length = max(12, mark.width * 4)
            for delta in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                path.move(to: last)
                path.line(to: CGPoint(x: last.x - cos(angle + delta) * length, y: last.y - sin(angle + delta) * length))
            }
        case .text:
            let font = NSFont.systemFont(ofSize: max(16, mark.width * 5), weight: .medium)
            let box = mark.rect
            // 有效盒子（宽高≥2）→ 透明背景 + 可选边框 + 自动换行；否则回退旧的单行绘制兼容存量与测试。
            if box.width >= 2, box.height >= 2 {
                let textInset = box.insetBy(dx: 6, dy: 5)
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                (mark.text as NSString).draw(with: textInset, options: [.usesLineFragmentOrigin],
                                              attributes: [.font: font, .foregroundColor: mark.color,
                                                           .paragraphStyle: paragraph])
                // 边框可选：默认不显示（不遮盖原内容），开启时按独立宽度描边。
                if mark.hasBorder {
                    let border = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
                    mark.color.setStroke(); border.lineWidth = mark.borderWidth; border.stroke()
                }
            } else {
                (mark.text as NSString).draw(at: first, withAttributes: [.font: font, .foregroundColor: mark.color])
            }
            return
        case .mosaic:
            let area = mark.rect.intersection(CGRect(origin: .zero, size: size)).integral
            guard area.width >= 1, area.height >= 1, let crop = source?.cropping(to: area),
                  let small = CGContext(data: nil, width: max(1, Int(area.width / 14)), height: max(1, Int(area.height / 14)),
                                        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            small.interpolationQuality = .medium
            small.draw(crop, in: CGRect(x: 0, y: 0, width: small.width, height: small.height))
            guard let pixels = small.makeImage() else { return }
            let old = NSGraphicsContext.current?.imageInterpolation
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: pixels, size: area.size).draw(in: area, from: .zero, operation: .copy,
                                                         fraction: 1, respectFlipped: true, hints: nil)
            if let old { NSGraphicsContext.current?.imageInterpolation = old }
            return
        }
        path.stroke()
    }

    /// 画布选中态的辅助描边（不进入导出）。
    func drawAnnotationSelectionRing(path: NSBezierPath, color: NSColor) {
        color.setStroke()
        path.stroke()
    }
}

/// 偶奇填充只压暗选区外，透明选区继续显示原图。
struct ScreenshotSelectionShade: Shape {
    let selection: CGRect
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(selection)
        return path
    }
}

struct ImageEditor: View {
    @State private var model: ImageEditorModel
    @State private var exporting = false
    @State private var options = false
    @State private var notice: String?
    @State private var error: String?
    @State private var imageOffset = CGSize.zero
    private weak var window: NSWindow?
    private let pasteboard: NSPasteboard
    private let canvasFrame: CGRect?
    private let inline: Bool
    let onPin: (NSImage) -> Void
    let onClose: () -> Void

    init(image: NSImage, window: NSWindow, pasteboard: NSPasteboard = .general,
         canvasFrame: CGRect? = nil, inline: Bool = false,
         onPin: @escaping (NSImage) -> Void, onClose: @escaping () -> Void) {
        _model = State(initialValue: ImageEditorModel(image: image))
        self.window = window; self.pasteboard = pasteboard
        self.canvasFrame = canvasFrame; self.inline = inline
        self.onPin = onPin; self.onClose = onClose
    }

    var body: some View {
        GeometryReader { geometry in
            let canvasRect = (canvasFrame
                ?? EditorLayout.imageRect(in: CGRect(origin: .zero, size: geometry.size), imageSize: model.size))
                .offsetBy(dx: imageOffset.width, dy: imageOffset.height)
            let imageRect = canvasRect
            ZStack(alignment: .topLeading) {
                if inline {
                    ScreenshotSelectionShade(selection: canvasRect)
                        .fill(.black.opacity(0.18), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                }
                ImageEditorCanvas(model: model, revision: model.revision,
                    annotating: model.isAnnotating && !exporting,
                    onClose: closeEditor,
                    onMove: inline ? { delta in
                        guard !exporting else { return }
                        imageOffset.width += min(max(delta.width, -canvasRect.minX), geometry.size.width - canvasRect.maxX)
                        imageOffset.height += min(max(delta.height, -canvasRect.minY), geometry.size.height - canvasRect.maxY)
                    } : nil)
                    .frame(width: canvasRect.width, height: canvasRect.height)
                    .overlay {
                        if inline { Rectangle().strokeBorder(.red, lineWidth: 1).allowsHitTesting(false) }
                    }
                    .position(x: canvasRect.midX, y: canvasRect.midY)
                    .accessibilityLabel("截图标注画布")
                controlsAnchor(imageRect: imageRect, bounds: CGRect(origin: .zero, size: geometry.size))
            }
        }
        .frame(minWidth: 240, minHeight: 120)
        .background { ScreenshotEscapeHandler(onEscape: closeEditor).frame(width: 0, height: 0).accessibilityHidden(true) }
        .onExitCommand(perform: closeEditor)
        .onChange(of: model.message) { notice = model.message }
        .task(id: notice) {
            guard notice != nil else { return }
            do { try await Task.sleep(for: .seconds(4)); notice = nil } catch { }
        }
        .alert("操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("确定") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func closeEditor() {
        guard !exporting else { return }
        onClose()
    }

    /// 工具条贴在图片下方外侧并右对齐；屏幕放不下时才翻到上方或重叠进图片。
    private func controlsAnchor(imageRect: CGRect, bounds: CGRect) -> some View {
        let compact = EditorLayout.usesCompactControls(in: imageRect)
        let size = EditorLayout.toolbarSize(compact: compact)
        let placement = EditorLayout.toolbarPlacement(imageRect: imageRect, toolbarSize: size, in: bounds)
        return controlsOverlay(imageRect: imageRect)
            .frame(width: size.width, height: size.height, alignment: placement.alignment)
            .position(x: placement.origin.x + size.width / 2, y: placement.origin.y + size.height / 2)
    }

    private func controlsOverlay(imageRect: CGRect) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if exporting {
                ProgressView("正在导出…").padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            } else if let notice {
                Text(notice).font(.caption).padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
            controls(compact: EditorLayout.usesCompactControls(in: imageRect))
        }
        .padding(EditorLayout.gap)
    }

    private func controls(compact: Bool) -> some View {
        Group {
            if compact {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 2) { annotationControls }
                    HStack(spacing: 2) { outputControls }
                }
            } else {
                HStack(spacing: 2) { annotationControls; outputControls }
            }
        }
        // 图标放大填满 30pt 命中区、间距收到 2pt，避免小图标在宽按钮间显得离得太远。
        .font(.system(size: 17))
        .buttonStyle(.borderless).padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.1)) }
    }

    private var annotationControls: some View {
        Group {
            Button {
                model.isAnnotating.toggle()
                if !model.isAnnotating { options = false }
            } label: {
                Image(systemName: "pencil.tip.crop.circle").frame(width: 30, height: 30).contentShape(Rectangle())
                    .background(model.isAnnotating ? PreferencesPalette.selection : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(model.isAnnotating ? PreferencesPalette.primary : .primary)
            }
                .help(model.isAnnotating ? "标注 · " + model.tool.rawValue + "；再次点击恢复拖动图片" : "标注工具")
                .accessibilityLabel("标注工具")
                .accessibilityValue(model.isAnnotating ? "已选中：" + model.tool.rawValue : "未选中")
                .disabled(exporting)
            Button { options.toggle() } label: {
                Image(systemName: model.tool.symbol).frame(width: 30, height: 30).contentShape(Rectangle())
                    .foregroundStyle(model.isAnnotating ? PreferencesPalette.primary : .primary)
            }
                .help("标注工具：" + model.tool.rawValue)
                .accessibilityLabel("标注工具选项")
                .accessibilityValue(model.tool.rawValue)
                .disabled(exporting)
                .popover(isPresented: $options, arrowEdge: .bottom) { toolOptions }
            Button(action: model.undo) { Image(systemName: "arrow.uturn.backward").frame(width: 30, height: 30).contentShape(Rectangle()) }
                .help("撤销").accessibilityLabel("撤销").disabled(exporting || model.annotations.isEmpty)
                .keyboardShortcut("z", modifiers: .command)
            Button(action: model.redo) { Image(systemName: "arrow.uturn.forward").frame(width: 30, height: 30).contentShape(Rectangle()) }
                .help("重做").accessibilityLabel("重做").disabled(exporting || model.undone.isEmpty)
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }

    private var outputControls: some View {
        Group {
            Button {
                perform {
                    let data = try await model.png()
                    pasteboard.clearContents()
                    guard pasteboard.setData(data, forType: .png) else { throw ClipError.invalid }
                    onClose()
                }
            } label: { Image(systemName: "doc.on.doc").frame(width: 30, height: 30).contentShape(Rectangle()) }
                .help("复制").accessibilityLabel("复制图片").disabled(exporting).keyboardShortcut("c", modifiers: .command)
            Button(action: save) { Image(systemName: "square.and.arrow.down").frame(width: 30, height: 30).contentShape(Rectangle()) }
                .help("保存 PNG").accessibilityLabel("保存图片").disabled(exporting).keyboardShortcut("s", modifiers: .command)
            Button { perform { onPin(try model.rendered()) } } label: { Image(systemName: "pin").frame(width: 30, height: 30).contentShape(Rectangle()) }
                .help("贴到屏幕").accessibilityLabel("贴到屏幕").disabled(exporting)
            Button(action: closeEditor) { Image(systemName: "xmark").frame(width: 30, height: 30).contentShape(Rectangle()) }
                .help("关闭截图").accessibilityLabel("关闭截图").keyboardShortcut(.cancelAction)
        }
    }

    private var toolOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(AnnotationTool.allCases, id: \.self) { tool in
                    Button {
                        model.select(tool)
                        options = false
                    } label: {
                        VStack(spacing: 5) {
                            Image(systemName: tool.symbol).font(.title3)
                            Text(tool.rawValue).font(.caption)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10).contentShape(Rectangle())
                        .foregroundStyle(model.tool == tool ? PreferencesPalette.primary : Color.primary)
                        .background(model.tool == tool ? PreferencesPalette.selection : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(model.tool == tool ? PreferencesPalette.primary : Color.secondary.opacity(0.2)) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("标注工具：" + tool.rawValue)
                    .accessibilityValue(model.tool == tool ? "已选中" : "未选中")
                }
            }
            ColorPicker("颜色", selection: $model.color, supportsOpacity: false)
            HStack {
                Text("笔宽 / 字号")
                Slider(value: $model.width, in: 2...20).accessibilityLabel("笔宽或字号")
                Text("\(Int(model.width))").monospacedDigit().frame(width: 24)
            }
            if model.tool == .text {
                Toggle("文字边框", isOn: $model.textBorderEnabled)
                if model.textBorderEnabled {
                    HStack {
                        Text("边框宽度")
                        Slider(value: $model.textBorderWidth, in: 1...12).accessibilityLabel("文字边框宽度")
                        Text("\(Int(model.textBorderWidth))").monospacedDigit().frame(width: 24)
                    }
                }
            }
            Button("完成") { options = false }.frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(16).frame(width: 280)
            .tint(PreferencesPalette.primary).preferredColorScheme(.light)
            .onExitCommand(perform: closeEditor)
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !exporting else { return }
        window?.makeFirstResponder(nil)
        options = false; exporting = true
        Task {
            defer { exporting = false }
            do { try await action() } catch { self.error = error.localizedDescription }
        }
    }

    private func save() {
        guard !exporting, let window else { return }
        options = false; exporting = true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "截图-\(Int(Date().timeIntervalSince1970)).png"
        // 依附图片窗口，避免非激活浮窗的独立保存面板丢失键盘焦点。
        panel.beginSheetModal(for: window) { response in
            exporting = false
            guard response == .OK, let url = panel.url else { return }
            perform { try await model.save(to: url); onClose() }
        }
    }
}

/// 监听仅覆盖当前截图及其工具子窗，保存面板保留原生取消语义。
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

private struct ImageEditorCanvas: NSViewRepresentable {
    let model: ImageEditorModel
    let revision: Int
    let annotating: Bool
    let onClose: () -> Void
    var onMove: ((CGSize) -> Void)? = nil
    func makeNSView(context: Context) -> AnnotationCanvas { AnnotationCanvas(model: model, onClose: onClose) }
    func updateNSView(_ view: AnnotationCanvas, context: Context) {
        view.sync(model: model, revision: revision, annotating: annotating, onClose: onClose, onMove: onMove)
    }
}

/// 只将鼠标坐标换算到原图一次，绘制和导出共用同一标注数据。
final class AnnotationCanvas: NSView, NSTextFieldDelegate {
    var model: ImageEditorModel
    var annotating = false
    var onClose: () -> Void
    var onMove: ((CGSize) -> Void)?
    private var movePoint: CGPoint?
    private var pending: ImageAnnotation?
    /// 正在选中的文字盒子索引（供高亮与拖角缩放）。
    private var selectedTextIndex: Int?
    /// 命中右下角缩放柄时记录 (索引, 原始盒)。
    private var textResize: (index: Int, box: CGRect)?
    /// 拖动选中文字盒子的上一事件图像素点，用于累积位移。
    private var textMovePoint: CGPoint?
    private(set) var textField: NSTextField?
    private var textEditingOrigin = CGPoint.zero
    /// 文字输入盒子（原图像素坐标）；随拖动定义，单点回退时 nil。
    private var textEditingBox: CGRect?
    private var textClickMonitor: Any?
    private var displayedRevision = -1
    private var backdropImage: NSImage?
    private var backdropRevision = -1
    private var backdropPixelSize = CGSize.zero
    private(set) var backdropBuilds = 0
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(model: ImageEditorModel, onClose: @escaping () -> Void) { self.model = model; self.onClose = onClose; super.init(frame: .zero) }
    override func cancelOperation(_ sender: Any?) { onClose() }
    required init?(coder: NSCoder) { nil }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, let monitor = textClickMonitor {
            NSEvent.removeMonitor(monitor)
            textClickMonitor = nil
        }
    }

    private var imageRect: CGRect { EditorLayout.imageRect(in: bounds, imageSize: model.size) }

    /// 文字沿用原图像素坐标；输入框字号按当前显示比例换算，导出的字号与预览一致。
    /// 文字工具的操作是“拖动先定义盒子”，松开才进入就地输入，故输入框按 `box` 定位。
    private func beginTextEditing(in box: CGRect) {
        commitTextEditing()
        let standardized = box.standardized
        let scale = imageRect.width / max(1, model.size.width)
        let fontSize = max(16, CGFloat(model.width) * 5) * scale
        let origin = CGPoint(x: imageRect.minX + standardized.minX * scale,
                             y: imageRect.minY + standardized.minY * scale)
        let field = NSTextField(frame: CGRect(x: origin.x, y: origin.y,
                                              width: max(standardized.width * scale, fontSize * 2),
                                              height: max(standardized.height * scale, fontSize * 2)))
        field.font = .systemFont(ofSize: fontSize)
        field.textColor = NSColor(model.color)
        field.stringValue = ""
        field.isBordered = true
        field.drawsBackground = true
        field.backgroundColor = .white.withAlphaComponent(0.85)
        field.placeholderString = "输入文字"
        field.delegate = self
        field.target = self
        field.action = #selector(commitTextEditing)
        textField = field
        textEditingOrigin = CGPoint(x: standardized.minX, y: standardized.minY)
        textEditingBox = standardized
        addSubview(field)
        window?.makeFirstResponder(field)
        textClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let field = self.textField else { return event }
            if !field.bounds.contains(field.convert(event.locationInWindow, from: nil)) {
                self.commitTextEditing()
            }
            return event
        }
    }

    @objc func commitTextEditing() {
        guard let field = textField else { return }
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let box = textEditingBox
        let origin = textEditingOrigin
        let fontSize = field.font?.pointSize ?? 16
        textField = nil
        textEditingBox = nil
        if let monitor = textClickMonitor { NSEvent.removeMonitor(monitor); textClickMonitor = nil }
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !string.isEmpty else { return }
        var mark: ImageAnnotation
        if let box, box.width >= 2, box.height >= 2 {
            // 盒子宽度自适应文字高度：按字体与盒宽量出完整换行高度，避免文字被裁切。
            let font = NSFont.systemFont(ofSize: max(16, model.width * 5), weight: .medium)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            let constraint = CGSize(width: max(1, box.width - 12), height: .greatestFiniteMagnitude)
            let measured = (string as NSString).boundingRect(with: constraint, options: [.usesLineFragmentOrigin],
                                                             attributes: [.font: font, .paragraphStyle: paragraph])
            let fittedBox = CGRect(x: box.origin.x, y: box.origin.y,
                                   width: box.width,
                                   height: max(box.height, ceil(measured.height) + 10))
            mark = ImageAnnotation(tool: .text, points: [fittedBox.origin, CGPoint(x: fittedBox.maxX, y: fittedBox.maxY)],
                                   color: NSColor(model.color), width: model.width, text: String(string.prefix(2000)))
            mark.hasBorder = model.textBorderEnabled
            mark.borderWidth = CGFloat(model.textBorderWidth)
        } else {
            mark = ImageAnnotation(tool: .text, points: [origin, CGPoint(x: origin.x + fontSize, y: origin.y)],
                                   color: NSColor(model.color), width: model.width, text: String(string.prefix(2000)))
            mark.hasBorder = model.textBorderEnabled
            mark.borderWidth = CGFloat(model.textBorderWidth)
        }
        model.append(mark)
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard textField != nil else { return }
        commitTextEditing()
    }

    /// 已完成标注按 revision 与画布分辨率缓存；交互期只渲染预览分辨率底图，不触碰全分辨率 `rendered()`。
    private func backdrop(for rect: CGRect) -> NSImage? {
        let scale = window?.backingScaleFactor ?? 1
        let pixels = CGSize(width: max(1, (rect.width * scale).rounded()),
                            height: max(1, (rect.height * scale).rounded()))
        if backdropRevision == model.revision, let image = backdropImage,
           Self.matches(backdropPixelSize, pixels) { return image }
        guard let scaled = try? model.preview(pixels: pixels, pointSize: rect.size) else { return nil }
        backdropImage = scaled; backdropRevision = model.revision; backdropPixelSize = pixels
        backdropBuilds += 1
        return scaled
    }

    /// 缩放容差内的窗口拖拽复用缓存，避免每一帧都重采样。
    private static func matches(_ cached: CGSize, _ target: CGSize) -> Bool {
        guard cached.width > 0, cached.height > 0 else { return false }
        return abs(cached.width - target.width) <= cached.width * 0.25
            && abs(cached.height - target.height) <= cached.height * 0.25
    }

    func sync(model: ImageEditorModel, revision: Int, annotating: Bool,
              onClose: @escaping () -> Void, onMove: ((CGSize) -> Void)?) {
        if self.model !== model {
            commitTextEditing()
            self.model = model
            backdropImage = nil
            backdropRevision = -1
            backdropPixelSize = .zero
            displayedRevision = -1
        }
        self.onClose = onClose
        self.onMove = onMove
        self.annotating = annotating
        guard revision != displayedRevision else { return }
        if textField != nil {
            commitTextEditing()
            displayedRevision = model.revision
            needsDisplay = true
            return
        }
        displayedRevision = revision
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        let rect = imageRect
        guard rect.width > 0, rect.height > 0 else { return }
        if let image = backdrop(for: rect) {
            image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            drawOverlay(rect)
        } else {
            guard textField == nil, let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            context.clip(to: rect)
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / model.size.width, y: rect.height / model.size.height)
            model.draw(pending: pending)
            drawSelectionHighlight()
            context.restoreGState()
        }
    }

    /// 在已完成标注底图之上叠加绘制中的标注与选中高亮（仅预览，不进导出）。
    private func drawOverlay(_ rect: CGRect) {
        guard textField == nil, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / model.size.width, y: rect.height / model.size.height)
        if let pending { model.draw(annotation: pending) }
        drawSelectionHighlight()
        context.restoreGState()
    }

    /// 画布高亮选中文字盒子（虚线外框 + 右下角缩放柄），仅原图像素坐标叠加层。
    private func drawSelectionHighlight() {
        guard let index = selectedTextIndex, model.annotations.indices.contains(index),
              let box = model.annotations[index].textAnnotatedRect else { return }
        let ring = NSBezierPath(rect: box.insetBy(dx: -3, dy: -3))
        ring.lineWidth = 2
        ring.setLineDash([6, 4], count: 2, phase: 0)
        model.drawAnnotationSelectionRing(path: ring, color: NSColor(model.color))
        let handle = NSBezierPath(ovalIn: CGRect(x: box.maxX - 8, y: box.maxY - 8, width: 16, height: 16))
        NSColor.white.setFill(); handle.fill()
        NSColor(model.color).setStroke(); handle.lineWidth = 2; handle.stroke()
    }

    private func point(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil), rect = imageRect
        return CGPoint(x: min(model.size.width, max(0, (local.x - rect.minX) * model.size.width / rect.width)),
                       y: min(model.size.height, max(0, (local.y - rect.minY) * model.size.height / rect.height)))
    }

    /// 命中原图像素点处的文字盒子索引（按最后添加优先）；无则 nil。
    private func textAnnotationIndex(at p: CGPoint) -> Int? {
        for index in model.annotations.indices.reversed() {
            if let box = model.annotations[index].textAnnotatedRect, box.contains(p) { return index }
        }
        return nil
    }

    /// 拖动画布选区时按 hitTest 优先给文字盒子；非文字工具直接交给画布。
    override func mouseDown(with event: NSEvent) {
        guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        // 全屏编辑只移动选区，避免把外围遮罩拖离桌面。
        guard annotating else {
            if onMove != nil { movePoint = event.locationInWindow }
            else { window?.performDrag(with: event) }
            return
        }
        commitTextEditing()
        let p = point(event)
        // 文字工具：先命中已有文字盒子（点击拖动移动／拖右下角缩放柄），否则划框新建。
        if model.tool == .text {
            if let index = textAnnotationIndex(at: p) {
                selectedTextIndex = index
                let box = model.annotations[index].rect
                // 落在右下角 32 像素缩放区内 → 进缩放，否则整体移动。
                let handle = CGRect(x: box.maxX - 32, y: box.maxY - 32, width: 32, height: 32)
                textResize = handle.contains(p) ? (index, box) : nil
                // 命中即记为移动起点，第一次拖动就能按位移移动，而不跳过首帧。
                textMovePoint = p
                needsDisplay = true
                return
            }
            pending = ImageAnnotation(tool: .text, points: [p], color: NSColor(model.color), width: model.width)
        } else {
            pending = ImageAnnotation(tool: model.tool, points: [p], color: NSColor(model.color), width: model.width)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let previous = movePoint {
            let current = event.locationInWindow
            movePoint = current
            onMove?(CGSize(width: current.x - previous.x, height: previous.y - current.y))
            return
        }
        // 拖动选中的文字盒子：有缩放柄则缩放，否则整体移动。
        if let resize = textResize, let selected = selectedTextIndex,
           model.annotations.indices.contains(selected) {
            let current = point(event)
            let origin = resize.box.origin
            let width = max(40, current.x - origin.x)
            let height = max(CGFloat(model.width) * 5, current.y - origin.y)
            model.setTextSize(at: selected, box: CGRect(origin: origin, size: CGSize(width: width, height: height)))
            needsDisplay = true
            return
        }
        if model.tool == .text, let selected = selectedTextIndex,
           model.annotations.indices.contains(selected), textResize == nil {
            let current = point(event)
            guard let previous = textMovePoint else { textMovePoint = current; return }
            model.translate(selected, by: CGSize(width: current.x - previous.x, height: current.y - previous.y))
            textMovePoint = current
            needsDisplay = true
            return
        }
        guard var mark = pending else { return }
        if mark.tool == .pen {
            if mark.points.count < 10000 { mark.points.append(point(event)) }
        } else { mark.points = [mark.points[0], point(event)] }
        pending = mark; needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        movePoint = nil
        textMovePoint = nil
        // 松开时保留选择（选中框继续亮显），仅结束本次拖动/缩放。
        textResize = nil
        guard let mark = pending else { return }
        pending = nil
        // 文字工具：拖动定义盒子，松开进入就地输入；单点回退默认宽度盒子。
        if model.tool == .text {
            if mark.rect.width >= 2, mark.rect.height >= 2 {
                beginTextEditing(in: mark.rect)
            } else {
                let first = mark.points.first ?? point(event)
                let defaultWidth = max(200, CGFloat(model.width) * 5 * 8)
                let defaultHeight = max(20, CGFloat(model.width) * 5 * 2)
                beginTextEditing(in: CGRect(x: first.x, y: first.y, width: defaultWidth, height: defaultHeight))
            }
            needsDisplay = true
            return
        }
        if mark.tool == .pen || mark.rect.width > 0 || mark.rect.height > 0 { model.append(mark) }
        needsDisplay = true
    }
}
