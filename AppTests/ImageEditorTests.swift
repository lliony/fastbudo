import AppKit
import SwiftUI
import Testing
@testable import FastBudo

@Suite(.serialized) @MainActor struct ImageEditorTests {
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
