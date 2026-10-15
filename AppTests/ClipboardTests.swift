import AppKit
import Testing
@testable import FastBudo

struct ClipboardStoreTests {
    func store() throws -> (ClipboardStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try ClipboardStore(directory: root), root)
    }
    @Test func persistenceDedupeSearchAndProtectedCleanup() throws {
        let (db, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try db.capture(.text("你好 SQLite %_"), source: "Tests", policy: .standard)
        var item = try #require(db.list(query: "SQLite %_").first)
        #expect(item.id == first)
        item.favorite = true
        item.group = "项目"
        try db.update(item)
        #expect(try db.capture(.text("你好 SQLite %_"), source: "Tests2", policy: .standard) == first)
        #expect(try db.list().count == 1)
        #expect(try db.list().first?.favorite == true)
        _ = try db.capture(.text("second"), source: "Tests", policy: .standard)
        _ = try db.capture(.text("third"), source: "Tests", policy: ClipPolicy(count: 1, days: 30, bytes: 100000))
        #expect(try db.list().count == 2)
        let reopened = try ClipboardStore(directory: root)
        #expect(try reopened.list().contains { $0.id == first && $0.group == "项目" })
        #expect(try reopened.payload(first).plainText == "你好 SQLite %_")
    }
    @Test func groupsRepliesAndQueuePersistIndependently() throws {
        let (db, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        try db.reply(id: nil, title: "问候", text: "你好", group: "工作", policy: .standard)
        var item = try #require(db.list(query: "问候").first)
        let order = item.order
        item.queued = true; item.queueOrder = 10
        try db.update(item)
        try db.deleteGroup("工作")
        let persisted = try #require(db.list().first)
        #expect(persisted.reply && persisted.queued)
        #expect(persisted.order == order)
        #expect(persisted.queueOrder == 10)
        #expect(persisted.group.isEmpty)
        #expect(try db.groups().isEmpty)
        #expect(try db.payload(item.id).plainText == "你好")
    }

    @Test func backupAndQuotaAreTransactional() throws {
        let (db, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try db.capture(.text("protected"), source: "Tests", policy: .standard)
        var item = try #require(db.list().first)
        item.pinned = true
        try db.update(item)
        #expect(throws: (any Error).self) {
            try db.capture(.text(String(repeating: "x", count: 10000)), source: "Tests", policy: ClipPolicy(count: 100, days: 30, bytes: 100))
        }
        #expect(try db.list().map(\.id) == [id])
        try db.addGroup("工作")
        let data = try db.exportData()
        let (other, secondRoot) = try store()
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        try other.importData(data, policy: .standard)
        try other.importData(data, policy: .standard)
        #expect(try other.list().count == 1)
        #expect(try other.groups() == ["工作"])
        #expect(throws: (any Error).self) { try other.importData(Data("bad".utf8), policy: .standard) }
        #expect(try other.list().count == 1)
    }
}

@MainActor struct ClipboardCaptureTests {
    @Test func roundTripAndSensitiveFiltering() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("合成内容", forType: .string)
        let payload = try #require(try ClipboardCapture.read(board))
        #expect(payload.plainText == "合成内容")
        try ClipboardCapture.write(payload, to: board, mode: .original)
        #expect(board.string(forType: .string) == "合成内容")
        #expect(try ClipboardCapture.read(board) == nil)
        board.clearContents()
        board.setString("not-secret-test", forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        #expect(try ClipboardCapture.read(board) == nil)
    }
    @Test func richTextAndImageRoundTrip() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let rich = NSAttributedString(string: "富文本样本", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        let rtf = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let payload = ClipPayload(items: [["public.rtf": rtf, "public.utf8-plain-text": Data("富文本样本".utf8)]])
        try ClipboardCapture.write(payload, to: board, mode: .original)
        #expect(board.data(forType: .rtf) == rtf)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        board.clearContents(); board.setData(png, forType: .png)
        let image = try #require(try ClipboardCapture.read(board))
        #expect(image.kind == .image)
        try ClipboardCapture.write(image, to: board, mode: .original)
        #expect(board.data(forType: .png) == png)
        #expect(throws: (any Error).self) { try ClipPayload(items: [["public.png": Data("invalid".utf8)]]).validate() }
        #expect(throws: (any Error).self) { try ClipPayload.text(String(repeating: "a", count: ClipPayload.maximum + 1)).validate() }
    }

    @Test func fileReferencesAndTextTransforms() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([URL(fileURLWithPath: "/tmp/test file.txt") as NSURL])
        let payload = try #require(try ClipboardCapture.read(board))
        #expect(payload.kind == .files)
        try ClipboardCapture.write(.text("a\nb c"), to: board, mode: .compact)
        #expect(board.string(forType: .string) == "abc")
        #expect(throws: (any Error).self) {
            try ClipPayload(items: [["public.file-url": Data("https://example.com".utf8)]]).validate()
        }
    }
}

@MainActor struct ClipboardControllerTests {
    @Test func blacklistSkipsNewSyntheticContent() {
        let suite = "ClipboardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: suite) }
        defaults.set("test.excluded", forKey: "clipExcluded")
        let controller = ClipboardController(defaults: defaults, board: board, sourceInfo: { ("test.excluded", "Tests") })
        controller.setEnabled(true)
        board.setString("blocked synthetic content", forType: .string)
        controller.poll()
        #expect(controller.items.isEmpty)
        #expect(controller.message == "正在记录新复制的内容")
    }

    @Test func optInSkipsExistingContentAndPauseStopsCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ClipboardTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        board.setString("existing synthetic content", forType: .string)
        let controller = ClipboardController(defaults: defaults, board: board, directory: root)
        controller.setEnabled(true)
        controller.poll()
        #expect(controller.items.isEmpty)
        board.clearContents(); board.setString("new synthetic content", forType: .string)
        controller.poll()
        let deadline = Date().addingTimeInterval(5)
        while controller.items.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(controller.items.count == 1)
        controller.setEnabled(false)
        board.clearContents(); board.setString("paused synthetic content", forType: .string)
        controller.poll()
        await controller.reload()
        #expect(controller.items.count == 1)
        #expect(controller.items.first?.preview == "new synthetic content")
    }
}
