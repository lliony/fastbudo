import AppKit
import Carbon
import Testing
@testable import FastBudo

@Suite(.serialized) struct ScreenshotTests {
    @Test func regionSelectionConvertsDesktopPointsWithoutScalingPixels() {
        let desktop = CGRect(x: -1280, y: -900, width: 3200, height: 1980)
        #expect(ScreenshotRegionSelector.captureRect(CGRect(x: -100, y: 100, width: 300, height: 200), desktop: desktop, primaryTop: 1080)
                == CGRect(x: -100, y: 780, width: 300, height: 200))
        #expect(ScreenshotRegionSelector.captureRect(CGRect(x: 100, y: -200, width: 200, height: 100), desktop: desktop, primaryTop: 1080)
                == CGRect(x: 100, y: 1180, width: 200, height: 100))
        #expect(ScreenshotRegionSelector.captureRect(CGRect(x: -1400, y: 0, width: 200, height: 100), desktop: desktop, primaryTop: 1080)
                == CGRect(x: -1280, y: 980, width: 80, height: 100))
        #expect(ScreenshotRegionSelector.captureRect(.zero, desktop: desktop, primaryTop: 1080) == nil)
        #expect(ScreenshotRegionSelector.captureRect(CGRect(x: 3000, y: 0, width: 10, height: 10), desktop: desktop, primaryTop: 1080) == nil)
    }

    @Test @MainActor func regionDragUsesEventCoordinatesWhenPointerHasAlreadyMoved() throws {
        var result: CGRect?
        let selector = ScreenshotRegionSelector { result = $0 }
        defer { selector.cancel() }
        selector.show()
        let window = try #require(NSApp.windows.first { $0.isVisible && $0.title == "FastBudo 区域选取" })
        let view = try #require(window.contentView)
        #expect(NSCursor.current == .arrow)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: type == .leftMouseUp ? .control : [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                            clickCount: 1, pressure: 1))
        }
        view.mouseDown(with: try event(.leftMouseDown, CGPoint(x: 20, y: 30)))
        view.mouseUp(with: try event(.leftMouseUp, CGPoint(x: 120, y: 90)))
        #expect(selector.copyToClipboard)
        let start = window.convertPoint(toScreen: CGPoint(x: 20, y: 30))
        let top = try #require(NSScreen.screens.first).frame.maxY
        #expect(result == CGRect(x: start.x, y: top - start.y - 60, width: 100, height: 60))
    }

    @Test @MainActor func stoppingCaptureReleasesPendingRegionSelection() async throws {
        let controller = ScreenshotController(defaults: UserDefaults(suiteName: "FastBudoStopCaptureTest")!, screenCaptureAccess: { true })
        controller.capture(.region)
        for _ in 0..<100 {
            if NSApp.windows.contains(where: { $0.isVisible && $0.title == "FastBudo 区域选取" }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        controller.stop()
        try await Task.sleep(for: .milliseconds(150))
        #expect(!controller.capturing)
        #expect(!NSApp.windows.contains { $0.isVisible && $0.title == "FastBudo 区域选取" })
    }

    @Test @MainActor func regionCancellationCompletesOnceAndReleasesOverlay() {
        var calls = 0
        let selector = ScreenshotRegionSelector { rect in #expect(rect == nil); calls += 1 }
        selector.show()
        selector.cancel(); selector.cancel()
        #expect(calls == 1)
        #expect(!NSApp.windows.contains { $0.isVisible && $0.title == "FastBudo 区域选取" })
    }

    @Test func editorWindowFitsVisibleScreen() {
        let screen = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        for size in [CGSize(width: 3840, height: 2160), CGSize(width: 80, height: 40),
                     CGSize(width: 300, height: 5000), CGSize(width: 6000, height: 300)] {
            let frame = ScreenshotController.editorFrame(imageSize: size, visibleFrame: screen, scale: 2)
            #expect(screen.contains(frame))
            #expect(frame.width >= 240 && frame.height >= 120)
        }
        let normal = ScreenshotController.editorFrame(imageSize: CGSize(width: 800, height: 600), visibleFrame: screen, scale: 2)
        #expect(normal.size == CGSize(width: 400, height: 300))
    }

    @Test @MainActor func hiddenAndClickThroughPinsCanBeRecoveredAndClosed() throws {
        let context = try #require(CGContext(data: nil, width: 20, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let controller = ScreenshotController()
        defer { controller.stop() }
        controller.pin(try #require(context.makeImage()))
        let pin = try #require(controller.pins.first)
        #expect(pin.panel.isVisible)
        pin.clickThrough = true; pin.opacity = 0.2
        controller.togglePins()
        #expect(!pin.panel.isVisible)
        controller.restorePins()
        #expect(pin.panel.isVisible && !pin.panel.ignoresMouseEvents && pin.panel.alphaValue == 1)
        controller.closePins()
        #expect(controller.pins.isEmpty)
        #expect(pin.panel.contentView == nil)
    }

    @Test @MainActor func copiedHistoryImageCanBePinnedWithoutRecapture() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let payload = ClipPayload(items: [["public.png": png]])
        try ClipboardCapture.write(payload, to: board)
        #expect(try ClipboardCapture.read(board) == nil)
        #expect(try ClipboardCapture.read(board, includeOwnWrites: true) == payload)
        let sensitive = NSPasteboardItem()
        sensitive.setData(png, forType: .png)
        sensitive.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        board.clearContents(); board.writeObjects([sensitive])
        #expect(try ClipboardCapture.read(board, includeOwnWrites: true) == nil)
    }

    @Test func pinBudgetRejectsUnboundedImages() {
        #expect(ScreenshotController.canPin(width: 200, height: 100, count: 0, existingPixels: 0))
        #expect(!ScreenshotController.canPin(width: 200, height: 100, count: 10, existingPixels: 0))
        #expect(!ScreenshotController.canPin(width: 200, height: 100, count: 1, existingPixels: 39_999_999))
        #expect(!ScreenshotController.canPin(width: Int.max, height: Int.max, count: 0, existingPixels: 0))
        #expect(!ScreenshotController.canPin(width: 0, height: 100, count: 0, existingPixels: 0))
    }

    @Test @MainActor func hotKeysOnlyMatchTheirOwnEvents() {
        let clipboard = ClipboardHotKey(), snip = ClipboardHotKey(identifier: 2), pin = ClipboardHotKey(identifier: 3)
        for id in UInt32(1)...3 {
            let event = EventHotKeyID(signature: 0x46424350, id: id)
            #expect(clipboard.matches(event) == (id == 1))
            #expect(snip.matches(event) == (id == 2))
            #expect(pin.matches(event) == (id == 3))
        }
        #expect(!clipboard.matches(EventHotKeyID(signature: 0, id: 1)))
    }

    @Test func transformsPreservePixelsAndSwapDimensions() throws {
        let context = try #require(CGContext(data: nil, width: 6, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 4))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 3, y: 0, width: 3, height: 4))
        let image = try #require(context.makeImage())
        let rotated = try #require(ScreenshotImage.transformed(image, turns: 1, horizontal: false, vertical: false))
        #expect(rotated.width == 4 && rotated.height == 6)
        let restored = try #require(ScreenshotImage.transformed(rotated, turns: -1, horizontal: false, vertical: false))
        #expect(restored.width == 6 && restored.height == 4)
        let flipped = try #require(ScreenshotImage.transformed(image, turns: 0, horizontal: true, vertical: false))
        let color = try #require(NSBitmapImageRep(cgImage: flipped).colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
        #expect(color.redComponent < 0.1 && color.blueComponent > 0.9)
        let roundtrip = try #require(ScreenshotImage.transformed(flipped, turns: 0, horizontal: true, vertical: false))
        #expect(roundtrip.dataProvider?.data == image.dataProvider?.data)
    }

    @Test @MainActor func rotationAfterSingleAxisFlipUsesVisualDirection() throws {
        let context = try #require(CGContext(data: nil, width: 6, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        let pin = PinnedImage(image: try #require(context.makeImage()))
        defer { pin.panel.contentView = nil; pin.panel.close() }
        pin.horizontal = true; pin.transform()
        let expected = try #require(ScreenshotImage.transformed(pin.image, turns: 1, horizontal: false, vertical: false))
        pin.rotate(1)
        #expect(pin.image.width == expected.width && pin.image.height == expected.height)
        #expect(pin.image.dataProvider?.data == expected.dataProvider?.data)
    }

    @Test @MainActor func repeatedPasteWhileDecodingOnlyCreatesOnePin() async throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let controller = ScreenshotController()
        defer { controller.stop() }
        controller.pinData(png); controller.pinData(png)
        for _ in 0..<100 where controller.pins.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(controller.pins.count == 1)
    }

    @Test func invalidImageRejectedBeforeDisplay() {
        #expect(throws: (any Error).self) { try ScreenshotImage.decode(Data("not an image".utf8)) }
        #expect(throws: (any Error).self) { try ScreenshotImage.decode(Data(count: ClipPayload.maximum + 1)) }
    }

    @Test func captureArgumentsKeepModesDistinct() {
        #expect(CaptureMode.region.arguments.isEmpty)
        #expect(CaptureMode.window.arguments == ["-i", "-w", "-o"])
        #expect(CaptureMode.screen(2).arguments == ["-D", "2"])
    }

    @Test @MainActor func quickOutputsUseChosenURLsAndSkipEditor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let board = NSPasteboard.withUniqueName()
        let name = "QuickScreenshotTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        var choices = [root.appendingPathComponent("first.png"), root.appendingPathComponent("second.png")]
        var prompts = 0
        let controller = ScreenshotController(defaults: defaults, pasteboard: board, saveDestination: {
            prompts += 1; return choices.removeFirst()
        })
        defer {
            controller.stop(); board.releaseGlobally(); defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 60,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(try #require(bitmap.bitmapData), 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let image = NSImage(size: NSSize(width: 40, height: 30)); image.addRepresentation(bitmap)
        let editors = NSApp.windows.filter { $0.title == "FastBudo 截图标注" }.count
        #expect(try await controller.deliver(image, action: .copy) == nil)
        #expect(prompts == 0)
        let copiedData = try #require(board.data(forType: .png))
        let copied = try #require(NSBitmapImageRep(data: copiedData))
        #expect(copied.pixelsWide == 80 && copied.pixelsHigh == 60)
        let changeCount = board.changeCount
        let first = try #require(try await controller.deliver(image, action: .download))
        let original = try Data(contentsOf: first)
        let second = try #require(try await controller.deliver(image, action: .download))
        #expect(prompts == 2 && first.lastPathComponent == "first.png" && second.lastPathComponent == "second.png")
        #expect(try Data(contentsOf: first) == original)
        #expect(try NSBitmapImageRep(data: Data(contentsOf: second))?.pixelsWide == 80)
        #expect(board.changeCount == changeCount)
        #expect(NSApp.windows.filter { $0.title == "FastBudo 截图标注" }.count == editors)
    }

    @Test @MainActor func cancelledSaveDoesNotWriteOrOverwrite() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let target = root.appendingPathComponent("existing.png")
        let original = Data("keep".utf8); try original.write(to: target, options: .withoutOverwriting)
        let board = NSPasteboard.withUniqueName()
        board.setString("独立剪贴板", forType: .string)
        let count = board.changeCount
        let name = "QuickSaveCancel." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        var selected: URL?
        let controller = ScreenshotController(defaults: defaults, pasteboard: board, saveDestination: { selected })
        defer {
            controller.stop(); board.releaseGlobally(); defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(try #require(bitmap.bitmapData), 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let image = NSImage(size: NSSize(width: 4, height: 4)); image.addRepresentation(bitmap)
        let editors = NSApp.windows.filter { $0.title == "FastBudo 截图标注" }.count
        #expect(try await controller.deliver(image, action: .download) == nil)
        #expect(NSApp.windows.filter { $0.title == "FastBudo 截图标注" }.count == editors)
        selected = target
        await #expect(throws: (any Error).self) { try await controller.deliver(image, action: .download) }
        #expect(try Data(contentsOf: target) == original)
        #expect(board.changeCount == count)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["existing.png"])
    }

    @Test func explicitDownloadIsNotChangedByControl() {
        #expect(CaptureAction.edit.effective(controlHeld: true) == .copy)
        #expect(CaptureAction.copy.effective(controlHeld: true) == .copy)
        #expect(CaptureAction.download.effective(controlHeld: true) == .download)
        #expect(CaptureAction.edit.effective(controlHeld: false) == .edit)
    }

    @Test @MainActor func stoppingBeforeDestinationReturnsPreventsOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let target = root.appendingPathComponent("stopped.png")
        let board = NSPasteboard.withUniqueName()
        board.setString("保留", forType: .string)
        let count = board.changeCount
        let name = "QuickSaveStop." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        var controller: ScreenshotController!
        controller = ScreenshotController(defaults: defaults, pasteboard: board, saveDestination: {
            controller.stop()
            return target
        })
        defer {
            controller.stop(); controller = nil
            board.releaseGlobally(); defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        memset(try #require(bitmap.bitmapData), 255, bitmap.bytesPerRow * bitmap.pixelsHigh)
        let image = NSImage(size: NSSize(width: 4, height: 4)); image.addRepresentation(bitmap)
        await #expect(throws: CancellationError.self) { try await controller.deliver(image, action: .download) }
        await #expect(throws: CancellationError.self) { try await controller.deliver(image, action: .copy) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(board.changeCount == count)
    }
}
