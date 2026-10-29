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

/// 标注保留原图像素坐标，预览缩放不改变最终导出尺寸。
@MainActor @Observable final class ImageEditorModel {
    let source: CGImage?
    var tool = AnnotationTool.rectangle
    var color = Color.red
    var width = 4.0
    var text = ""
    var message = "选择工具后在图片上拖动；文字工具在点击处添加文字。"
    private(set) var annotations: [ImageAnnotation] = []
    private(set) var undone: [ImageAnnotation] = []
    private(set) var revision = 0

    init(image: NSImage) {
        var rect = CGRect(origin: .zero, size: image.size)
        source = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    var size: CGSize { CGSize(width: source?.width ?? 1, height: source?.height ?? 1) }

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

    func rendered() throws -> NSImage {
        guard let source,
              let context = CGContext(data: nil, width: source.width, height: source.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ClipError.invalid }
        context.translateBy(x: 0, y: CGFloat(source.height)); context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        defer { NSGraphicsContext.restoreGraphicsState() }
        draw(pending: nil)
        guard let result = context.makeImage() else { throw ClipError.invalid }
        return NSImage(cgImage: result, size: size)
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
        for annotation in annotations { draw(annotation) }
        if let pending { draw(pending) }
    }

    private func draw(_ mark: ImageAnnotation) {
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
    @State private var annotating = false
    @State private var notice: String?
    @State private var error: String?
    @State private var imageOffset = CGSize.zero
    private weak var window: NSWindow?
    private let pasteboard: NSPasteboard
    private let canvasFrame: CGRect?
    private let controlsFrame: CGRect?
    let onPin: (NSImage) -> Void
    let onClose: () -> Void

    init(image: NSImage, window: NSWindow, pasteboard: NSPasteboard = .general,
         canvasFrame: CGRect? = nil, controlsFrame: CGRect? = nil,
         onPin: @escaping (NSImage) -> Void, onClose: @escaping () -> Void) {
        _model = State(initialValue: ImageEditorModel(image: image))
        self.window = window; self.pasteboard = pasteboard
        self.canvasFrame = canvasFrame; self.controlsFrame = controlsFrame
        self.onPin = onPin; self.onClose = onClose
    }

    var body: some View {
        GeometryReader { geometry in
            let imageRect = canvasFrame?.offsetBy(dx: imageOffset.width, dy: imageOffset.height)
                ?? CGRect(origin: .zero, size: geometry.size)
            let toolsRect = controlsFrame?.offsetBy(dx: imageOffset.width, dy: imageOffset.height)
                ?? CGRect(origin: .zero, size: geometry.size)
            ZStack(alignment: .bottomTrailing) {
                if canvasFrame != nil {
                    ScreenshotSelectionShade(selection: imageRect)
                        .fill(.black.opacity(0.18), style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                }
                ImageEditorCanvas(model: model, revision: model.revision, annotating: annotating && !exporting,
                    onClose: closeEditor, onMove: canvasFrame == nil ? nil : { delta in
                        guard !exporting else { return }
                        imageOffset.width += min(max(delta.width, -imageRect.minX), geometry.size.width - imageRect.maxX)
                        imageOffset.height += min(max(delta.height, -imageRect.minY), geometry.size.height - imageRect.maxY)
                    })
                    .frame(width: imageRect.width, height: imageRect.height)
                    .overlay {
                        if canvasFrame != nil { Rectangle().strokeBorder(.red, lineWidth: 1).allowsHitTesting(false) }
                    }
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .accessibilityLabel("截图标注画布")
                VStack(alignment: .trailing, spacing: 6) {
                    if exporting {
                        ProgressView("正在导出…").padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    } else if let notice {
                        Text(notice).font(.caption).padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                    controls(compact: toolsRect.width < 340)
                }.padding(8)
                    .frame(width: toolsRect.width, height: toolsRect.height, alignment: .bottomTrailing)
                    .position(x: toolsRect.midX, y: toolsRect.midY)
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

    private func controls(compact: Bool) -> some View {
        Group {
            if compact {
                VStack(alignment: .trailing, spacing: 4) {
                    HStack(spacing: 4) { annotationControls }
                    HStack(spacing: 4) { outputControls }
                }
            } else {
                HStack(spacing: 4) { annotationControls; outputControls }
            }
        }
        .buttonStyle(.borderless).padding(6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.1)) }
    }

    private var annotationControls: some View {
        Group {
            Button {
                annotating.toggle()
                options = annotating
            } label: {
                Image(systemName: "pencil.tip.crop.circle").frame(width: 28, height: 28)
                    .background(annotating ? PreferencesPalette.selection : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                    .foregroundStyle(annotating ? PreferencesPalette.primary : .primary)
            }
                .help(annotating ? "标注 · " + model.tool.rawValue + "；再次点击恢复拖动图片" : "标注工具")
                .accessibilityLabel("标注工具")
                .accessibilityValue(annotating ? "已选中：" + model.tool.rawValue : "未选中")
                .disabled(exporting)
                .popover(isPresented: $options, arrowEdge: .bottom) { toolOptions }
            Button(action: model.undo) { Image(systemName: "arrow.uturn.backward").frame(width: 28, height: 28) }
                .help("撤销").accessibilityLabel("撤销").disabled(exporting || model.annotations.isEmpty)
                .keyboardShortcut("z", modifiers: .command)
            Button(action: model.redo) { Image(systemName: "arrow.uturn.forward").frame(width: 28, height: 28) }
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
            } label: { Image(systemName: "doc.on.doc").frame(width: 28, height: 28) }
                .help("复制").accessibilityLabel("复制图片").disabled(exporting).keyboardShortcut("c", modifiers: .command)
            Button(action: save) { Image(systemName: "square.and.arrow.down").frame(width: 28, height: 28) }
                .help("保存 PNG").accessibilityLabel("保存图片").disabled(exporting).keyboardShortcut("s", modifiers: .command)
            Button { perform { onPin(try model.rendered()) } } label: { Image(systemName: "pin").frame(width: 28, height: 28) }
                .help("贴到屏幕").accessibilityLabel("贴到屏幕").disabled(exporting)
            Button(action: closeEditor) { Image(systemName: "xmark").frame(width: 28, height: 28) }
                .help("关闭截图").accessibilityLabel("关闭截图").keyboardShortcut(.cancelAction)
        }
    }

    private var toolOptions: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(AnnotationTool.allCases, id: \.self) { tool in
                    Button { model.tool = tool } label: {
                        VStack(spacing: 5) {
                            Image(systemName: tool.symbol).font(.title3)
                            Text(tool.rawValue).font(.caption)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 10)
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
                TextField("输入文字后在图片上点击", text: $model.text).textFieldStyle(.roundedBorder)
            }
            Button("完成") { options = false }.frame(maxWidth: .infinity, alignment: .trailing)
        }.padding(16).frame(width: 280)
            .tint(PreferencesPalette.primary).preferredColorScheme(.light)
            .onExitCommand(perform: closeEditor)
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !exporting else { return }
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
        view.model = model; view.annotating = annotating; view.onClose = onClose
        view.onMove = onMove; view.needsDisplay = true
    }
}

/// 只将鼠标坐标换算到原图一次，绘制和导出共用同一标注数据。
final class AnnotationCanvas: NSView {
    var model: ImageEditorModel
    var annotating = false
    var onClose: () -> Void
    var onMove: ((CGSize) -> Void)?
    private var movePoint: CGPoint?
    private var pending: ImageAnnotation?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(model: ImageEditorModel, onClose: @escaping () -> Void) { self.model = model; self.onClose = onClose; super.init(frame: .zero) }
    override func cancelOperation(_ sender: Any?) { onClose() }
    required init?(coder: NSCoder) { nil }

    private var imageRect: CGRect {
        let scale = min(max(1, bounds.width) / model.size.width, max(1, bounds.height) / model.size.height)
        let size = CGSize(width: model.size.width * scale, height: model.size.height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill(); bounds.fill(using: .copy)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = imageRect
        context.saveGState()
        context.clip(to: rect)
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: rect.width / model.size.width, y: rect.height / model.size.height)
        model.draw(pending: pending)
        context.restoreGState()
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
        let point = point(event)
        let mark = ImageAnnotation(tool: model.tool, points: [point], color: NSColor(model.color), width: model.width, text: String(model.text.prefix(2000)))
        if model.tool == .text {
            guard !mark.text.isEmpty else { model.message = "请先输入要标注的文字。"; return }
            model.append(mark)
        } else { pending = mark }
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
