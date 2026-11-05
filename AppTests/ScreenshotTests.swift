import AppKit
import Carbon
import Testing
import SwiftUI
@testable import FastBudo

@Suite(.serialized) struct ScreenshotTests {
    @Test @MainActor func regionActionsShowSelectionWithoutSystemCaptureDelay() async throws {
        for action in [CaptureAction.edit, .copy, .download] {
            let name = "RegionStartTests." + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: name))
            let board = NSPasteboard.withUniqueName()
            let controller = ScreenshotController(defaults: defaults, screenCaptureAccess: { true }, pasteboard: board)
            defer { controller.stop(); board.releaseGlobally(); defaults.removePersistentDomain(forName: name) }
            let started = ContinuousClock.now
            controller.capture(.region, action: action)
            var visible = false
            while started.duration(to: .now) < .milliseconds(150) {
                visible = NSApp.windows.contains { $0.isVisible && $0.title == "FastBudo 区域选取" }
                if visible { break }
                try await Task.sleep(for: .milliseconds(2))
            }
            print("region selection \(action): \(started.duration(to: .now))")
            #expect(visible, "区域选区应跳过系统截图的350ms等待：\(action)")
        }
    }

    @Test func shadeLeavesOnlySelectionClear() {
        let selection = CGRect(x: 200, y: 100, width: 300, height: 200)
        let path = ScreenshotSelectionShade(selection: selection).path(in: CGRect(x: 0, y: 0, width: 1200, height: 800))
        #expect(path.contains(CGPoint(x: 100, y: 100), eoFill: true))
        #expect(!path.contains(CGPoint(x: 300, y: 200), eoFill: true))
        #expect(path.contains(CGPoint(x: 900, y: 600), eoFill: true))
    }
    @Test @MainActor func inlineEditorReusesPanelAndPreservesPixels() throws {
        let screen = try #require(NSScreen.main)
        let selection = CGRect(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.minY + 40, width: 400, height: 300)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let image = NSImage(size: selection.size)
        image.addRepresentation(bitmap)
        let panel = PinnedImagePanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        let number = panel.windowNumber
        let windows = Set(NSApp.windows.map(\.windowNumber))
        let controller = ScreenshotController()
        defer { controller.stop() }
        controller.edit(image, in: panel, selectionFrame: selection)
        #expect(panel.windowNumber == number)
        // 编辑继续覆盖桌面，外围灰色遮罩不能随选区一起缩小。
        #expect(panel.frame == screen.frame)
        #expect(!panel.hasShadow)
        #expect(Set(NSApp.windows.map(\.windowNumber)).subtracting(windows).isEmpty)
        #expect(ImageEditorModel(image: image).size == CGSize(width: 800, height: 600))
        #expect(panel.level == .floating)
        panel.close()
        #expect(panel.contentView == nil)
    }

    @Test @MainActor func finishedSelectionTransfersPanelExactlyOnce() throws {
        var calls = 0
        var received: RegionSelection?
        let selector = ScreenshotRegionSelector { received = $0; calls += 1 }
        selector.show()
        let panel = try #require(NSApp.windows.first { $0.isVisible && $0.title == "FastBudo 区域选取" })
        let view = try #require(panel.contentView)
        for (type, point) in [(NSEvent.EventType.leftMouseDown, CGPoint(x: 40, y: 40)),
                              (.leftMouseUp, CGPoint(x: 140, y: 100))] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: panel.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
        _ = try #require(received)
        #expect(calls == 1)
        let transferred = try #require(selector.takeTransferredPanel())
        #expect(transferred === panel)
        #expect(!transferred.isVisible)
        selector.cancel(); selector.cancel()
        #expect(calls == 1)
        #expect(transferred.contentView != nil)
        #expect(selector.takeTransferredPanel() == nil)
        transferred.contentView = nil; transferred.close()
    }

    @Test func captureGeometryRoundTripsScreenAndCaptureCoordinates() throws {
        let desktop = CGRect(x: -1280, y: -900, width: 3200, height: 1980)
        let primaryTop: CGFloat = 1080
        let screen = CGRect(x: 100, y: 200, width: 300, height: 150)
        let capture = try #require(CaptureGeometry.captureRect(screen, desktop: desktop, primaryTop: primaryTop))
        #expect(capture == CGRect(x: 100, y: 730, width: 300, height: 150))
        #expect(CaptureGeometry.screenFrame(capture, primaryTop: primaryTop) == screen)
        #expect(CaptureGeometry.flippedLocal(screen, in: CGRect(x: 0, y: 0, width: 1000, height: 800))
                == CGRect(x: 100, y: 450, width: 300, height: 150))
    }

    @Test func regionSelectionConvertsDesktopPointsWithoutScalingPixels() {
        let desktop = CGRect(x: -1280, y: -900, width: 3200, height: 1980)
        #expect(CaptureGeometry.captureRect(CGRect(x: -100, y: 100, width: 300, height: 200), desktop: desktop, primaryTop: 1080)
                == CGRect(x: -100, y: 780, width: 300, height: 200))
        #expect(CaptureGeometry.captureRect(CGRect(x: 100, y: -200, width: 200, height: 100), desktop: desktop, primaryTop: 1080)
                == CGRect(x: 100, y: 1180, width: 200, height: 100))
        #expect(CaptureGeometry.captureRect(CGRect(x: -1400, y: 0, width: 200, height: 100), desktop: desktop, primaryTop: 1080)
                == CGRect(x: -1280, y: 980, width: 80, height: 100))
        #expect(CaptureGeometry.captureRect(.zero, desktop: desktop, primaryTop: 1080) == nil)
        #expect(CaptureGeometry.captureRect(CGRect(x: 3000, y: 0, width: 10, height: 10), desktop: desktop, primaryTop: 1080) == nil)
    }

    @Test @MainActor func regionDragUsesEventCoordinatesWhenPointerHasAlreadyMoved() throws {
        var received: RegionSelection?
        let selector = ScreenshotRegionSelector { received = $0 }
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
        let selection = try #require(received)
        let transferred = try #require(selector.takeTransferredPanel())
        #expect(transferred === window)
        #expect(!transferred.isVisible)
        selector.cancel()
        #expect(transferred.contentView != nil)
        defer { transferred.contentView = nil; transferred.close() }
        #expect(selection.copyToClipboard)
        let start = window.convertPoint(toScreen: CGPoint(x: 20, y: 30))
        let top = try #require(NSScreen.screens.first).frame.maxY
        #expect(selection.captureRect == CGRect(x: start.x, y: top - start.y - 60, width: 100, height: 60))
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

    @Test func editorWindowEnlargesSmallCaptureWithoutDistortion() {
        let screen = CGRect(x: -1440, y: 200, width: 1440, height: 900)
        let wide = ScreenshotController.editorFrame(
            imageSize: CGSize(width: 400, height: 100), visibleFrame: screen, scale: 2)
        #expect(wide.size == CGSize(width: 480, height: 120))
        #expect(wide.midX == screen.midX)
        #expect(wide.midY == screen.midY)
    }

    @Test func pinToolbarShowsAllActionsOnlyWhenTheyFit() {
        let expected: [PinnedImageAction] = [
            .zoomOut, .zoomIn, .rotateCounterclockwise, .rotateClockwise,
            .flipHorizontal, .flipVertical, .opacity, .copy
        ]
        let layout = PinnedImageToolbarLayout.split(availableWidth: 268)
        #expect(PinnedImageAction.allCases == expected)
        #expect(layout.visible == expected)
        #expect(layout.overflow.isEmpty)
    }

    @Test func pinToolbarReservesMoreButtonBelowFullThreshold() {
        let layout = PinnedImageToolbarLayout.split(availableWidth: 267)
        #expect(!layout.overflow.isEmpty)
        #expect(layout.visible.count == 6)
        #expect(layout.overflow == [.flipHorizontal, .flipVertical])
    }

    @Test func pinToolbarHandlesMinimumAndInvalidWidths() {
        let minimum = PinnedImageToolbarLayout.split(availableWidth: 240)
        #expect(minimum.visible == [.zoomOut, .zoomIn, .rotateCounterclockwise, .rotateClockwise, .opacity, .copy])
        #expect(minimum.overflow == [.flipHorizontal, .flipVertical])
        for width in [CGFloat.zero, -1] {
            let layout = PinnedImageToolbarLayout.split(availableWidth: width)
            #expect(layout.visible.isEmpty)
            #expect(layout.overflow == PinnedImageAction.allCases)
        }
    }

    @Test func pinToolbarNeverDuplicatesOrDropsActions() {
        for width in [CGFloat.zero, 120, 240, 267, 268, 800] {
            let layout = PinnedImageToolbarLayout.split(availableWidth: width)
            let combined = layout.visible + layout.overflow
            #expect(Set(combined) == Set(PinnedImageAction.allCases))
            #expect(combined.count == PinnedImageAction.allCases.count)
        }
    }

    @Test @MainActor func pinToolbarActionsUseExistingModelBehavior() throws {
        let context = try #require(CGContext(data: nil, width: 6, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let board = NSPasteboard.withUniqueName()
        let pin = PinnedImage(image: image, pasteboard: board)
        defer { pin.panel.contentView = nil; pin.panel.close(); board.releaseGlobally() }

        #expect(pin.perform(.zoomOut) == .none)
        #expect(pin.zoom == 0.8)
        #expect(pin.perform(.zoomIn) == .none)
        #expect(pin.zoom == 1)
        #expect(pin.perform(.rotateCounterclockwise) == .none)
        #expect(pin.turns == 1)
        #expect(pin.perform(.rotateClockwise) == .none)
        #expect(pin.turns == 0)
        #expect(pin.perform(.flipHorizontal) == .none)
        #expect(pin.horizontal)
        #expect(pin.perform(.flipVertical) == .none)
        #expect(pin.vertical)
        #expect(pin.perform(.opacity) == .showOpacity)
        #expect(pin.perform(.copy) == .none)
        #expect(board.availableType(from: [.tiff, .png]) != nil)
    }

    @Test @MainActor func pinToolbarSelectionReflectsPersistentState() throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let pin = PinnedImage(image: try #require(context.makeImage()))
        defer { pin.panel.contentView = nil; pin.panel.close() }

        for action in PinnedImageAction.allCases {
            #expect(!pin.isActive(action))
        }
        _ = pin.perform(.flipHorizontal)
        _ = pin.perform(.flipVertical)
        pin.opacity = 0.5
        #expect(pin.isActive(.flipHorizontal))
        #expect(pin.isActive(.flipVertical))
        #expect(pin.isActive(.opacity))
        #expect(!pin.isActive(.zoomOut))
        #expect(!pin.isActive(.copy))
    }

    @Test @MainActor func pinImageSurfaceMovesWindowFromDragEvents() throws {
        let panel = PinnedImagePanel(
            contentRect: NSRect(x: 100, y: 120, width: 200, height: 160),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let surface = PinnedImageDragSurface()
        panel.contentView = surface
        defer { panel.contentView = nil; panel.close() }
        let mouseDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 10, y: 10),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        let mouseDragged = try #require(NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: CGPoint(x: 40, y: 35),
            modifierFlags: [],
            timestamp: 0.1,
            windowNumber: panel.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 1
        ))

        surface.mouseDown(with: mouseDown)
        surface.mouseDragged(with: mouseDragged)

        #expect(panel.frame.origin == CGPoint(x: 130, y: 145))
    }

    @Test @MainActor func closingPinReleasesViewAndNotifiesOwner() throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let pin = PinnedImage(image: try #require(context.makeImage()))
        var closed = 0
        pin.onClosed = { closed += 1 }
        #expect(pin.panel.contentView != nil)
        pin.close()
        #expect(pin.panel.contentView == nil)
        #expect(closed == 1)
    }

    @Test @MainActor func pinnedImageUsesScreensaverLevel() throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let pin = PinnedImage(image: try #require(context.makeImage()))
        // 贴图需盖过启动器/工具弹出框（如 utools），与区域选区一致用 screenSaver 置顶层。
        #expect(pin.panel.level == .screenSaver)
        pin.close()
    }

    @Test @MainActor func pinClosedDirectlyIsRemovedFromController() throws {
        let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let controller = ScreenshotController()
        defer { controller.stop() }
        controller.pin(try #require(context.makeImage()))
        let pin = try #require(controller.pins.first)
        // 不经控制器的关闭路径，也不能残留持有环或列表引用。
        pin.close()
        #expect(controller.pins.isEmpty)
        #expect(pin.panel.contentView == nil)
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
