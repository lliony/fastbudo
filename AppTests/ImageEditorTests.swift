import AppKit
import SwiftUI
import Testing
@testable import FastBudo

@Suite(.serialized) @MainActor struct ImageEditorTests {
    @Test func inlineDragMovesSelectionWithoutMovingDesktopOrDrawing() throws {
        let model = ImageEditorModel(image: try fixture())
        let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvas(model: model, onClose: {})
        window.contentView = canvas
        defer { window.contentView = nil; window.close() }
        let frame = window.frame
        var delta = CGSize.zero
        canvas.onMove = { delta = $0 }
        for (type, point) in [(NSEvent.EventType.leftMouseDown, CGPoint(x: 100, y: 100)),
                              (.leftMouseDragged, CGPoint(x: 130, y: 80)),
                              (.leftMouseUp, CGPoint(x: 130, y: 80))] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { canvas.mouseDown(with: event) }
            else if type == .leftMouseDragged { canvas.mouseDragged(with: event) }
            else { canvas.mouseUp(with: event) }
        }
        #expect(delta == CGSize(width: 30, height: 20))
        #expect(window.frame == frame)
        #expect(model.annotations.isEmpty)
    }

    @Test func escapeIsScopedToEditorAndItsChildWindow() throws {
        let editor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        let child = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        for window in [editor, other, child] { window.isReleasedWhenClosed = false }
        let handler = ScreenshotEscapeView()
        var calls = 0
        handler.onEscape = { calls += 1 }
        editor.contentView = handler
        editor.addChildWindow(child, ordered: .above)
        defer {
            handler.stop(); editor.removeChildWindow(child)
            for window in [editor, other, child] { window.contentView = nil; window.close() }
        }
        func escape(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = [], keyCode: UInt16 = 53) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: keyCode))
        }
        #expect(handler.handle(try escape(editor)) == nil)
        #expect(handler.handle(try escape(child)) == nil)
        #expect(handler.handle(try escape(other)) != nil)
        for modifiers: NSEvent.ModifierFlags in [.command, .control, .option] {
            #expect(handler.handle(try escape(editor, modifiers: modifiers)) != nil)
        }
        #expect(handler.handle(try escape(editor, keyCode: 0)) != nil)
        #expect(calls == 2)
        editor.removeChildWindow(child)
        editor.beginSheet(child)
        #expect(editor.attachedSheet === child)
        #expect(handler.handle(try escape(editor)) != nil)
        #expect(handler.handle(try escape(child)) != nil)
        #expect(calls == 2)
        editor.endSheet(child)
    }

    private func control(_ node: NSObject, label: String) -> NSObject? {
        // SwiftUI 的辅助节点实现访问方法，但不声明 NSAccessibilityProtocol。
        let accessible = node as? any NSAccessibilityProtocol
        let role = accessible?.accessibilityRole() ?? (node.value(forKey: "accessibilityRole") as? String).map(NSAccessibility.Role.init(rawValue:))
        let title = accessible?.accessibilityLabel() ?? (node.value(forKey: "accessibilityLabel") as? String)
        if role == .button && title == label { return node }
        let children = accessible?.accessibilityChildren() ?? (node.accessibilityAttributeValue(.children) as? [Any]) ?? []
        for child in children {
            if let child = child as? NSObject, let match = control(child, label: label) { return match }
        }
        return nil
    }

    @Test func copyWritesPNGThenClosesEditor() async throws {
        let board = NSPasteboard.withUniqueName()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var closed = false
        let view = NSHostingView(rootView: ImageEditor(image: try fixture(), window: window, pasteboard: board,
            onPin: { _ in }, onClose: { closed = true }))
        defer { window.orderOut(nil); window.contentView = nil; board.releaseGlobally() }
        window.contentView = view; window.orderFront(nil); view.layoutSubtreeIfNeeded()
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        try await Task.sleep(for: .milliseconds(150))
        let button = try #require(control(view, label: "复制图片"))
        _ = button.perform(NSSelectorFromString("accessibilityPerformPress"))
        for _ in 0..<100 where !closed { try await Task.sleep(for: .milliseconds(10)) }
        let data = try #require(board.data(forType: .png))
        let result = try #require(NSBitmapImageRep(data: data))
        #expect(result.pixelsWide == 80 && result.pixelsHigh == 60)
        #expect(closed)
    }

    @Test func saveSheetCancellationKeepsEditorAvailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fastbudo-save-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let board = NSPasteboard.withUniqueName()
        let window = PinnedImagePanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
                                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var closed = false
        let view = NSHostingView(rootView: ImageEditor(image: try fixture(), window: window, pasteboard: board,
            onPin: { _ in }, onClose: { closed = true }))
        let originalWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        defer {
            for panel in NSApp.windows.compactMap({ $0 as? NSSavePanel }) where !originalWindows.contains(ObjectIdentifier(panel)) { panel.cancel(nil) }
            window.orderOut(nil); window.contentView = nil; board.releaseGlobally()
            try? FileManager.default.removeItem(at: root)
        }
        window.contentView = view; window.orderFrontRegardless(); window.makeKey(); view.layoutSubtreeIfNeeded()
        NSApp.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        try await Task.sleep(for: .milliseconds(150))
        _ = try #require(control(view, label: "保存图片")).perform(NSSelectorFromString("accessibilityPerformPress"))
        try await Task.sleep(for: .milliseconds(150))
        let cancelledPanel = try #require(window.attachedSheet as? NSSavePanel)
        #expect(!closed)
        cancelledPanel.directoryURL = root; cancelledPanel.nameFieldStringValue = "cancelled.png"
        cancelledPanel.cancel(nil)
        for _ in 0..<100 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(10)) }
        let savedFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!closed && savedFiles.isEmpty)
        _ = try #require(control(view, label: "保存图片")).perform(NSSelectorFromString("accessibilityPerformPress"))
        try await Task.sleep(for: .milliseconds(150))
        let panel = try #require(window.attachedSheet as? NSSavePanel)
        panel.cancel(nil)
        for _ in 0..<100 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!closed)
    }

    @Test func layoutFitsImageInsideBounds() {
        let bounds = CGRect(x: 10, y: 20, width: 400, height: 300)
        #expect(EditorLayout.imageRect(in: bounds, imageSize: CGSize(width: 400, height: 200))
            == CGRect(x: 10, y: 70, width: 400, height: 200))
        #expect(EditorLayout.imageRect(in: bounds, imageSize: CGSize(width: 100, height: 100))
            == CGRect(x: 60, y: 20, width: 300, height: 300))
        #expect(EditorLayout.imageRect(in: .zero, imageSize: CGSize(width: 10, height: 10)) == .zero)
    }

    @Test func compactControlsFollowImageSize() {
        #expect(!EditorLayout.usesCompactControls(in: CGRect(x: 0, y: 0, width: 400, height: 300)))
        #expect(EditorLayout.usesCompactControls(in: CGRect(x: 0, y: 0, width: 240, height: 120)))
    }

    @Test func toolbarSitsOutsideImageBottomRight() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let image = CGRect(x: 300, y: 300, width: 400, height: 300)
        let size = EditorLayout.toolbarSize(compact: false)
        #expect(size.width == EditorLayout.regularSize.width + EditorLayout.gap * 2)
        let placement = EditorLayout.toolbarPlacement(imageRect: image, toolbarSize: size, in: bounds)
        #expect(placement.origin.y == image.maxY)
        #expect(placement.origin.x + size.width == image.maxX)
        #expect(placement.origin.y + size.height <= bounds.maxY)
        // 顶对齐让可见条子贴着图片下缘，而不是沉到预留框底部。
        #expect(placement.alignment == .topTrailing)
    }

    @Test func toolbarFlipsAboveWhenBottomHasNoRoom() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let image = CGRect(x: 300, y: 700, width: 400, height: 150)
        let size = EditorLayout.toolbarSize(compact: false)
        let placement = EditorLayout.toolbarPlacement(imageRect: image, toolbarSize: size, in: bounds)
        #expect(placement.origin.y + size.height == image.minY)
        #expect(placement.alignment == .bottomTrailing)
    }

    @Test func toolbarFallsBackInsideFullBleedImage() {
        let bounds = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let image = bounds
        let size = EditorLayout.toolbarSize(compact: false)
        let placement = EditorLayout.toolbarPlacement(imageRect: image, toolbarSize: size, in: bounds)
        #expect(placement.origin.y + size.height == image.maxY)
        #expect(placement.origin.x + size.width == image.maxX)
        #expect(placement.alignment == .bottomTrailing)
    }

    @Test func detachedWindowReservesToolbarBelowImage() throws {
        let controller = ScreenshotController()
        controller.edit(try fixture())
        let window = try #require(NSApp.windows.first { $0.title == "FastBudo 截图标注" })
        let toolbar = EditorLayout.toolbarSize(compact: true)
        #expect(window.frame.height >= 180 + toolbar.height + EditorLayout.inset * 3 - 1)
        window.close()
    }

    @Test func selectingToolEntersAnnotation() throws {
        let model = ImageEditorModel(image: try fixture())
        #expect(!model.isAnnotating)
        model.select(.arrow)
        #expect(model.tool == .arrow)
        #expect(model.isAnnotating)
    }

    @Test(arguments: [AnnotationTool.rectangle, .ellipse, .arrow, .pen, .mosaic])
    func dragCreatesAnnotationForTool(_ tool: AnnotationTool) throws {
        let model = ImageEditorModel(image: try fixture())
        model.select(tool)
        let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvas(model: model, onClose: {})
        window.contentView = canvas
        canvas.annotating = true
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100), window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 140, y: 130), window: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 140, y: 130), window: window))
        #expect(model.annotations.count == 1)
        #expect(model.annotations.first?.tool == tool)
        #expect(((model.annotations.first?.rect.width) ?? 0) > 0)
    }

    @Test func penAcceptsDragAtImageBottomRight() throws {
        let model = ImageEditorModel(image: try fixture())
        model.select(.pen)
        let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvas(model: model, onClose: {})
        window.contentView = canvas
        canvas.annotating = true
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 380, y: 280), window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 300, y: 200), window: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 300, y: 200), window: window))
        #expect(model.annotations.count == 1)
        #expect(((model.annotations.first?.points.count) ?? 0) >= 2)
    }

    private func mouse(_ type: NSEvent.EventType, at point: CGPoint, window: NSWindow) -> NSEvent {
        // 测试窗口未上屏，合成事件的 locationInWindow 等于传入的 location；
        // 画布是 flipped，这里把测试用的视图坐标换成未翻转的窗口坐标。
        let contentHeight = window.contentView?.bounds.height ?? window.frame.height
        let location = CGPoint(x: point.x, y: contentHeight - point.y)
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                  windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                  clickCount: 1, pressure: 1)!
    }

    @Test func toolSwitchDoesNotRedrawCanvas() throws {
        let model = ImageEditorModel(image: try fixture())
        let canvas = AnnotationCanvas(model: model, onClose: {})
        canvas.sync(model: model, revision: model.revision, annotating: false, onClose: {}, onMove: nil)
        canvas.needsDisplay = false
        model.select(.arrow)
        canvas.sync(model: model, revision: model.revision, annotating: true, onClose: {}, onMove: nil)
        #expect(!canvas.needsDisplay)
    }

    @Test func backdropRebuildsOnlyOnRevisionChange() throws {
        let model = ImageEditorModel(image: try fixture())
        let canvas = AnnotationCanvas(model: model, onClose: {})
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 300,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        func render() throws {
            let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            canvas.draw(canvas.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        try render()
        try render()
        #expect(canvas.backdropBuilds == 1)
        model.append(ImageAnnotation(tool: .rectangle,
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)]))
        canvas.sync(model: model, revision: model.revision, annotating: false, onClose: {}, onMove: nil)
        try render()
        #expect(canvas.backdropBuilds == 2)
    }

    @Test func renderResultIsReusedUntilAnnotationsChange() throws {
        let model = ImageEditorModel(image: try fixture())
        let first = try model.rendered()
        #expect(try model.rendered() === first)
        model.append(ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)]))
        #expect(try model.rendered() !== first)
    }

    @Test func backdropReusesDisplayImageUntilSizeChangesSignificantly() throws {
        let model = ImageEditorModel(image: try fixture())
        let canvas = AnnotationCanvas(model: model, onClose: {})
        canvas.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        func render() throws {
            let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 450,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            canvas.draw(canvas.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }
        try render()
        #expect(canvas.backdropBuilds == 1)
        canvas.frame = CGRect(x: 0, y: 0, width: 430, height: 322)
        try render()
        #expect(canvas.backdropBuilds == 1)
        canvas.frame = CGRect(x: 0, y: 0, width: 600, height: 450)
        try render()
        #expect(canvas.backdropBuilds == 2)
    }

    @Test func displayCacheKeepsImageOrientation() throws {
        let model = ImageEditorModel(image: try fixture())
        let canvas = AnnotationCanvas(model: model, onClose: {})
        canvas.frame = CGRect(x: 0, y: 0, width: 80, height: 60)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        let top = try #require(rep.colorAt(x: 40, y: 2)?.usingColorSpace(.deviceRGB))
        let bottom = try #require(rep.colorAt(x: 40, y: 57)?.usingColorSpace(.deviceRGB))
        #expect(top.redComponent > 0.9 && top.blueComponent < 0.1)
        #expect(bottom.blueComponent > 0.9 && bottom.redComponent < 0.1)
    }

    @Test func textDragDefinesBoxAndCommitsTypedText() throws {
        let model = ImageEditorModel(image: try textFixture())
        let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvas(model: model, onClose: {})
        window.contentView = canvas
        defer { window.contentView = nil; window.close() }

        model.select(.text)
        canvas.annotating = true
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 150), window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 200, y: 180), window: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 200, y: 180), window: window))
        let field = try #require(canvas.textField)
        let imageRect = EditorLayout.imageRect(in: canvas.bounds, imageSize: model.size)
        #expect(imageRect.contains(CGPoint(x: field.frame.minX, y: field.frame.minY)))
        field.stringValue = "Strut"
        canvas.commitTextEditing()

        #expect(model.annotations.count == 1)
        let mark = try #require(model.annotations.first)
        #expect(mark.text == "Strut")
        // 输入条目的两点应来自拖动定义的盒子（宽≥2、高≥2）。
        #expect(mark.rect.width >= 2)
        #expect(mark.rect.height >= 2)
        #expect(canvas.textField == nil)
    }

    @Test func emptyTextCommitAddsNothing() throws {
        let model = ImageEditorModel(image: try textFixture())
        let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvas(model: model, onClose: {})
        window.contentView = canvas
        defer { window.contentView = nil; window.close() }

        model.select(.text)
        canvas.annotating = true
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 150), window: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 100, y: 150), window: window))
        let field = try #require(canvas.textField)
        field.stringValue = "   "
        canvas.commitTextEditing()

        #expect(model.annotations.isEmpty)
        #expect(canvas.textField == nil)
    }

    @Test func singleClickOpensDefaultWidthTextBox() throws {
        let model = ImageEditorModel(image: try textFixture())
        let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvas(model: model, onClose: {})
        window.contentView = canvas
        defer { window.contentView = nil; window.close() }

        model.select(.text)
        canvas.annotating = true
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 100, y: 150), window: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 100, y: 150), window: window))
        let field = try #require(canvas.textField)
        // 单点（无有效拖动）回退默认宽度盒子，输入框至少能容纳一个字。
        #expect(field.frame.width >= field.font!.pointSize * 2)
    }

    @Test func clickingTextBoxAndDraggingMovesIt() throws {
        let model = ImageEditorModel(image: try textFixture())
        let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvas(model: model, onClose: {})
        window.contentView = canvas
        defer { window.contentView = nil; window.close() }

        model.select(.text)
        model.append(ImageAnnotation(tool: .text,
                                     points: [CGPoint(x: 50, y: 40), CGPoint(x: 150, y: 90)],
                                     color: .systemGreen, width: 4, text: "移动"))
        canvas.annotating = true
        let before = model.annotations[0].points
        // 点→像素 ×2；盒 (50,40)-(150,90) 像素 → 点 (25,20)-(75,45)。
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 32), window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 70, y: 52), window: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 70, y: 52), window: window))
        let after = model.annotations[0].points
        #expect(after[0].x == before[0].x + 40)
        #expect(after[0].y == before[0].y + 40)
        #expect(after[1].x == before[1].x + 40)
        #expect(after[1].y == before[1].y + 40)
    }

    @Test func draggingResizeCornerResizesTextBox() throws {
        let model = ImageEditorModel(image: try textFixture())
        let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvas(model: model, onClose: {})
        window.contentView = canvas
        defer { window.contentView = nil; window.close() }

        model.select(.text)
        model.append(ImageAnnotation(tool: .text,
                                     points: [CGPoint(x: 50, y: 40), CGPoint(x: 150, y: 90)],
                                     color: .systemGreen, width: 4, text: "缩放"))
        canvas.annotating = true
        // 右下角缩放区：盒 (50,40)-(150,90) 像素 → 区内 (74,44) 点。
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 74, y: 44), window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 115, y: 65), window: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 115, y: 65), window: window))
        let rect = model.annotations[0].rect
        #expect(rect.width == 180)
        #expect(rect.height == 90)
    }

    /// 文字标注的字号按显示比例换算；用 800×600 像素、400×300 点的图避免输入框高过画布。
    private func textFixture() throws -> NSImage {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: CGSize(width: 400, height: 300))
        image.addRepresentation(bitmap)
        return image
    }

    private func fixture() throws -> NSImage {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.bitmapData)
        for y in 0..<60 {
            for x in 0..<80 {
                let i = y * bitmap.bytesPerRow + x * 4
                let shade: UInt8 = (x + y) % 2 == 0 ? 255 : 0
                bytes[i] = y < 8 ? 255 : y > 51 ? 0 : shade
                bytes[i + 1] = y < 8 || y > 51 ? 0 : shade
                bytes[i + 2] = y > 51 ? 255 : y < 8 ? 0 : shade
                bytes[i + 3] = 255
            }
        }
        let image = NSImage(size: NSSize(width: 40, height: 30))
        image.addRepresentation(bitmap)
        return image
    }

    @Test func exportRetainsRetinaPixelsAndOrientation() async throws {
        let model = ImageEditorModel(image: try fixture())
        let png = try await model.png()
        let result = try #require(NSBitmapImageRep(data: png))
        #expect(result.pixelsWide == 80 && result.pixelsHigh == 60)
        let top = try #require(result.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        let bottom = try #require(result.colorAt(x: 0, y: 59)?.usingColorSpace(.deviceRGB))
        #expect(top.redComponent > 0.9 && top.blueComponent < 0.1)
        #expect(bottom.blueComponent > 0.9 && bottom.redComponent < 0.1)
    }

    @Test func everyAnnotationToolChangesExportedPixels() async throws {
        for tool in AnnotationTool.allCases {
            let model = ImageEditorModel(image: try fixture())
            let before = try await model.png()
            model.append(ImageAnnotation(tool: tool, points: [CGPoint(x: 10, y: 12), CGPoint(x: 60, y: 45)],
                                         color: .systemGreen, width: 4, text: "测试"))
            let after = try await model.png()
            #expect(before != after, "\(tool.rawValue) 必须改变导出像素")
            let result = try #require(NSBitmapImageRep(data: after))
            #expect(result.pixelsWide == 80 && result.pixelsHigh == 60)
            if tool == .mosaic {
                let pixel = try #require(result.colorAt(x: 30, y: 30)?.usingColorSpace(.deviceRGB))
                #expect(pixel.redComponent > 0.1 && pixel.redComponent < 0.9)
            }
        }
    }

    @Test func undoRedoRestoresPixelsAndNewEditClearsRedo() async throws {
        let model = ImageEditorModel(image: try fixture())
        let original = try await model.png()
        let mark = ImageAnnotation(tool: .rectangle, points: [CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 40)])
        model.append(mark)
        let edited = try await model.png()
        model.undo()
        #expect(try await model.png() == original)
        model.redo()
        #expect(try await model.png() == edited)
        model.undo(); model.append(mark)
        #expect(model.undone.isEmpty)
    }

    @Test func translateAndResizeTextBoxUpdatePixels() async throws {
        let model = ImageEditorModel(image: try textFixture())
        let mark = ImageAnnotation(tool: .text, points: [CGPoint(x: 40, y: 30), CGPoint(x: 160, y: 100)],
                                   color: .systemRed, width: 4, text: "换行测试 WrapBox")
        model.append(mark)
        let before = try await model.png()
        model.translate(0, by: CGSize(width: 30, height: 20))
        let moved = try await model.png()
        #expect(before != moved, "移动盒子必须改变导出像素")
        model.setTextSize(at: 0, box: CGRect(x: 60, y: 50, width: 90, height: 30))
        let resized = try await model.png()
        #expect(moved != resized, "缩放盒子必须改变导出像素")
    }

    @Test func textWrapsInsideBoxOnExport() async throws {
        let model = ImageEditorModel(image: try textFixture())
        // 窄盒 + 长文本：渲染结果必须是被换行约束到盒内的像素（比单行裸文本高）。
        let mark = ImageAnnotation(tool: .text, points: [CGPoint(x: 40, y: 40), CGPoint(x: 150, y: 200)],
                                   color: .systemBlue, width: 4, text: "这是一段很长需要在框内自动换行的文字内容")
        model.append(mark)
        let boxed = try await model.png()
        // 同尺寸裸文本沿单行绘制（无盒子时回退），两者像素必须不同。
        let fallback = ImageEditorModel(image: try textFixture())
        fallback.append(ImageAnnotation(tool: .text, points: [CGPoint(x: 40, y: 40)],
                                        color: .systemBlue, width: 4, text: "这是一段很长需要在框内自动换行的文字内容"))
        let raw = try await fallback.png()
        #expect(boxed != raw, "盒子渲染必须与单行裸文本不同")
    }

    @Test func textCommitAutoFitsBoxHeight() throws {
        let model = ImageEditorModel(image: try textFixture())
        let window = NSPanel(contentRect: CGRect(x: 10, y: 20, width: 400, height: 300),
                             styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = AnnotationCanvas(model: model, onClose: {})
        window.contentView = canvas
        defer { window.contentView = nil; window.close() }

        model.select(.text)
        canvas.annotating = true
        // 拖动一个很矮的盒子（高度远小于多行文字所需）。
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 60, y: 60), window: window))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, at: CGPoint(x: 200, y: 64), window: window))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 200, y: 64), window: window))
        let field = try #require(canvas.textField)
        field.stringValue = "这是一段很长的需要多行换行的文字内容来验证高度自适应"
        canvas.commitTextEditing()

        let mark = try #require(model.annotations.last)
        // 高度必须容纳完整文字（比原始拖框高度大得多），文字不被裁切。
        #expect(mark.rect.height > 10)
    }

    @Test func textBorderToggleRendersDistinctPixels() async throws {
        let model = ImageEditorModel(image: try textFixture())
        model.append(ImageAnnotation(tool: .text, points: [CGPoint(x: 50, y: 50), CGPoint(x: 180, y: 120)],
                                     color: .systemRed, width: 4, text: "带边框文字"))
        let plain = try await model.png()
        let bordered = ImageEditorModel(image: try textFixture())
        var mark = ImageAnnotation(tool: .text, points: [CGPoint(x: 50, y: 50), CGPoint(x: 180, y: 120)],
                                   color: .systemRed, width: 4, text: "带边框文字")
        mark.hasBorder = true
        mark.borderWidth = 4
        bordered.append(mark)
        let withBorder = try await bordered.png()
        #expect(plain != withBorder, "开启边框必须改变导出像素")
    }

    @Test func saveNeverOverwritesExistingOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fastbudo-editor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("output.png")
        let model = ImageEditorModel(image: try fixture())
        try await model.save(to: target)
        let original = try Data(contentsOf: target)
        model.append(ImageAnnotation(tool: .text, points: [CGPoint(x: 10, y: 20)], text: "changed"))
        await #expect(throws: (any Error).self) { try await model.save(to: target) }
        #expect(try Data(contentsOf: target) == original)
    }
}
