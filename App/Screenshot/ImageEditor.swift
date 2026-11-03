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

    var rect: CGRect {
        guard let first = points.first, let last = points.last else { return .zero }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                      width: abs(last.x - first.x), height: abs(last.y - first.y))
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
        let image = try rendered()
        var rect = CGRect(origin: .zero, size: size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw ClipError.invalid }
        return cg
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
            (mark.text as NSString).draw(at: first, withAttributes: [.font: font, .foregroundColor: mark.color])
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
    private(set) var textField: NSTextField?
    private var textEditingOrigin = CGPoint.zero
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
    private func beginTextEditing(at point: CGPoint) {
        commitTextEditing()
        let scale = imageRect.width / max(1, model.size.width)
        let fontSize = max(16, CGFloat(model.width) * 5) * scale
        let origin = CGPoint(x: imageRect.minX + point.x * scale, y: imageRect.minY + point.y * scale)
        let field = NSTextField(frame: CGRect(x: origin.x, y: origin.y, width: max(160, fontSize * 8),
                                              height: fontSize * 2))
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
        textEditingOrigin = point
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
        let origin = textEditingOrigin
        let fontSize = field.font?.pointSize ?? 16
        textField = nil
        if let monitor = textClickMonitor { NSEvent.removeMonitor(monitor); textClickMonitor = nil }
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        guard !string.isEmpty else { return }
        let mark = ImageAnnotation(tool: .text, points: [origin, CGPoint(x: origin.x + fontSize, y: origin.y)],
                                   color: NSColor(model.color), width: model.width, text: String(string.prefix(2000)))
        model.append(mark)
        needsDisplay = true
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard textField != nil else { return }
        commitTextEditing()
    }

    /// 已完成标注按 revision 与画布分辨率缓存，拖动期间只叠加绘制中的标注，不再逐帧缩放原图。
    private func backdrop(for rect: CGRect) -> NSImage? {
        let scale = window?.backingScaleFactor ?? 1
        let pixels = CGSize(width: max(1, (rect.width * scale).rounded()),
                            height: max(1, (rect.height * scale).rounded()))
        if backdropRevision == model.revision, let image = backdropImage,
           Self.matches(backdropPixelSize, pixels) { return image }
        guard let source = try? model.rendered(), let scaled = Self.scaled(source, to: pixels, pointSize: rect.size) else { return nil }
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

    private static func scaled(_ source: NSImage, to pixels: CGSize, pointSize: CGSize) -> NSImage? {
        let width = Int(pixels.width), height = Int(pixels.height)
        var rect = CGRect(origin: .zero, size: source.size)
        guard width > 0, height > 0,
              let image = source.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return NSImage(cgImage: scaled, size: pointSize)
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
            guard textField == nil, let pending, let context = NSGraphicsContext.current?.cgContext else { return }
            context.saveGState()
            context.clip(to: rect)
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / model.size.width, y: rect.height / model.size.height)
            model.draw(annotation: pending)
            context.restoreGState()
        } else if textField == nil, let context = NSGraphicsContext.current?.cgContext {
            context.saveGState()
            context.clip(to: rect)
            context.translateBy(x: rect.minX, y: rect.minY)
            context.scaleBy(x: rect.width / model.size.width, y: rect.height / model.size.height)
            model.draw(pending: pending)
            context.restoreGState()
        }
    }

    private func point(_ event: NSEvent) -> CGPoint {
        let local = convert(event.locationInWindow, from: nil), rect = imageRect
        return CGPoint(x: min(model.size.width, max(0, (local.x - rect.minX) * model.size.width / rect.width)),
                       y: min(model.size.height, max(0, (local.y - rect.minY) * model.size.height / rect.height)))
    }

    override func mouseDown(with event: NSEvent) {
        guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        // 全屏编辑只移动选区，避免把外围遮罩拖离桌面。
        guard annotating else {
            if onMove != nil { movePoint = event.locationInWindow }
            else { window?.performDrag(with: event) }
            return
        }
        if model.tool == .text {
            beginTextEditing(at: point(event))
            return
        }
        commitTextEditing()
        pending = ImageAnnotation(tool: model.tool, points: [point(event)], color: NSColor(model.color), width: model.width)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let previous = movePoint {
            let current = event.locationInWindow
            movePoint = current
            onMove?(CGSize(width: current.x - previous.x, height: previous.y - current.y))
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
        guard let mark = pending else { return }
        pending = nil
        if mark.tool == .pen || mark.rect.width > 0 || mark.rect.height > 0 { model.append(mark) }
        needsDisplay = true
    }
}
