import AppKit
import SwiftUI
import Testing
import SQLite3
@testable import FastBudo

struct ClipboardStoreTests {
    func store() throws -> (ClipboardStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (try ClipboardStore(directory: root), root)
    }
    @Test func metadataEditKeepsLatestUse() throws {
        let (db, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try db.capture(.text("最近使用"), source: "Tests", policy: .standard)
        var stale = try #require(db.list().first)
        let latest = try db.markUsed(id)
        stale.favorite = true
        try db.update(stale.id, favorite: stale.favorite)
        let saved = try #require(db.list().first)
        #expect(saved.used == latest.used)
        #expect(saved.favorite)
    }

    @Test func metadataEditsPreservePayloadAndLiteralSearch() throws {
        let (db, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try db.capture(.text("正文 %_"), source: "Tests", policy: .standard)
        var raw: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("clipboard.sqlite").path, &raw) == SQLITE_OK)
        defer { sqlite3_close(raw) }
        // 拒绝重写内容及替换整行，确保普通编辑不会重新编码大内容。
        #expect(sqlite3_exec(raw, "CREATE TRIGGER no_payload BEFORE UPDATE OF payload ON clips BEGIN SELECT RAISE(ABORT,'payload'); END; CREATE TRIGGER no_replace BEFORE INSERT ON clips BEGIN SELECT RAISE(ABORT,'replace'); END;", nil, nil, nil) == SQLITE_OK)
        try db.update(id, title: "旧标题😀", group: "工作", favorite: true)
        try db.update(id, title: "新标题", pinned: true)
        try db.deleteGroup("工作")
        #expect(try db.matchingIDs("旧标题").isEmpty)
        #expect(try db.matchingIDs("新标题") == [id])
        #expect(try db.matchingIDs("%_") == [id])
        #expect(try db.matchingIDs("不存在").isEmpty)
        #expect(try db.payload(id).plainText == "正文 %_")
        let item = try #require(db.list().first)
        #expect(item.favorite && item.pinned && item.group.isEmpty)
        #expect(throws: (any Error).self) { try db.update(id, title: String(repeating: "a", count: 1001)) }
        #expect(try db.list().first?.title == "新标题")
    }

    @Test func capacityCleanupEvictsOldestAndRollsBackWhenProtected() throws {
        let (db, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let protected = try db.capture(.text("保留"), source: "Tests", policy: .standard)
        try db.update(protected, favorite: true)
        let old = try db.capture(.text(String(repeating: "a", count: 2000)), source: "Tests", policy: .standard)
        let recent = try db.capture(.text("最近"), source: "Tests", policy: .standard)
        try db.clean(ClipPolicy(count: 100, days: 30, bytes: 3000))
        #expect(Set(try db.list().map(\.id)) == [protected, recent])
        #expect(throws: (any Error).self) { try db.payload(old) }
        #expect(throws: (any Error).self) { try db.clean(ClipPolicy(count: 1, days: 30, bytes: 1)) }
        #expect(Set(try db.list().map(\.id)) == [protected, recent])
    }

    @Test func failedExportPreservesExistingBackup() throws {
        let (db, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try db.capture(.text("测试"), source: "Tests", policy: .standard)
        let backup = root.appendingPathComponent("backup.json")
        let previous = Data("已有备份".utf8)
        try previous.write(to: backup)
        var raw: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("clipboard.sqlite").path, &raw) == SQLITE_OK)
        defer { sqlite3_close(raw) }
        #expect(sqlite3_exec(raw, "UPDATE clips SET payload=x'00'", nil, nil, nil) == SQLITE_OK)
        #expect(throws: (any Error).self) { try db.exportBackup(to: backup) }
        #expect(try Data(contentsOf: backup) == previous)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasSuffix(".tmp") })
    }

    @Test func oversizedBackupIsRejectedBeforeReading() throws {
        let (db, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("oversized.json")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(ClipboardStore.backupLimit) + 1)
        #expect(throws: ClipError.backupTooLarge) { try db.importBackup(from: url, policy: .standard) }
        #expect(try db.list().isEmpty)
    }

    @Test func streamingBackupSupportsLegacyJSONAndRollsBackMalformedTail() throws {
        let (db, root) = try store()
        let (other, destination) = try store()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: destination) }
        let payload = String(repeating: "边界\n\"\\", count: 20000)
        let id = try db.capture(.text(payload), source: "Tests", policy: .standard)
        try db.update(id, title: #"括号 } ], " 与反斜线 \"#, group: "测试")
        let backup = root.appendingPathComponent("backup.json")
        try Data("已有文件".utf8).write(to: backup)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: backup.path)
        try db.exportBackup(to: backup)
        #expect((try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as! [String: Any]
        let legacy = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try legacy.write(to: backup)
        var malformed = legacy; malformed.removeLast()
        try malformed.write(to: backup)
        #expect(throws: (any Error).self) { try other.importBackup(from: backup, policy: .standard) }
        #expect(try other.list().isEmpty)
        #expect(try other.groups().isEmpty)
        try legacy.write(to: backup)
        try other.importBackup(from: backup, policy: .standard)
        #expect(try other.payload(id).plainText == payload)
        #expect(try other.groups() == ["测试"])
        var duplicate = object
        let records = object["records"] as! [[String: Any]]
        duplicate["records"] = records + records
        try JSONSerialization.data(withJSONObject: duplicate).write(to: backup)
        #expect(throws: (any Error).self) { try other.importBackup(from: backup, policy: .standard) }
        #expect(try other.list().count == 1)
        for invalid in ["{\"version\":1,\"groups\":[],\"records\":[],}",
                        "{\"version\":1,\"groups\":[],\"records\":[]}x",
                        "{\"version\":2,\"groups\":[],\"records\":[]}"] {
            try Data(invalid.utf8).write(to: backup)
            #expect(throws: (any Error).self) { try other.importBackup(from: backup, policy: .standard) }
        }
    }

    @Test func persistenceDedupeSearchAndProtectedCleanup() throws {
        let (db, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try db.capture(.text("你好 SQLite %_"), source: "Tests", policy: .standard)
        var item = try #require(db.list(query: "SQLite %_").first)
        #expect(item.id == first)
        item.favorite = true
        item.group = "项目"
        try db.update(item.id, group: item.group, favorite: item.favorite, pinned: item.pinned, queued: item.queued, queueOrder: item.queueOrder)
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
        try db.update(item.id, group: item.group, favorite: item.favorite, pinned: item.pinned, queued: item.queued, queueOrder: item.queueOrder)
        try db.deleteGroup("工作")
        let persisted = try #require(db.list().first)
        #expect(persisted.reply && persisted.queued)
        #expect(persisted.order == order)
        #expect(persisted.queueOrder == 10)
        #expect(persisted.group.isEmpty)
        #expect(try db.groups().isEmpty)
        #expect(try db.payload(item.id).plainText == "你好")
    }

    @Test func legacyDuplicatesMigrateWithoutRewritingPayload() throws {
        let (db, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try db.capture(.text("迁移测试"), source: "Tests", policy: .standard)
        var item = try #require(db.list().first)
        item.favorite = true; item.group = "保留分组"; item.queued = true; item.queueOrder = 42
        try db.update(item.id, group: item.group, favorite: item.favorite, pinned: item.pinned, queued: item.queued, queueOrder: item.queueOrder)
        var raw: OpaquePointer?
        #expect(sqlite3_open(root.appendingPathComponent("clipboard.sqlite").path, &raw) == SQLITE_OK)
        defer { sqlite3_close(raw) }
        let duplicate = UUID().uuidString
        // 构造旧版本数据库；触发器确保迁移和再次使用都不更新大内容列。
        let sql = "INSERT INTO clips SELECT '\(duplicate)', CAST(json_set(CAST(meta AS TEXT),'$.id','\(duplicate)') AS BLOB), payload, hash, search, bytes FROM clips; PRAGMA user_version=1; CREATE TRIGGER no_payload_rewrite BEFORE UPDATE OF payload ON clips BEGIN SELECT RAISE(ABORT,'payload rewritten'); END;"
        #expect(sqlite3_exec(raw, sql, nil, nil, nil) == SQLITE_OK)
        let reopened = try ClipboardStore(directory: root)
        let kept = try #require(reopened.list().first)
        #expect(try reopened.list().count == 1)
        #expect(kept.favorite && kept.queued && kept.group == "保留分组")
        #expect(kept.queueOrder == 42)
        _ = try reopened.markUsed(kept.id)
        #expect(try reopened.payload(kept.id).plainText == "迁移测试")
        #expect(try reopened.capture(.text("迁移测试"), source: "Again", policy: .standard) == kept.id)
        #expect(throws: (any Error).self) { try reopened.capture(.text("迁移测试"), source: String(repeating: "x", count: 301), policy: .standard) }
        #expect(kept.id == id || kept.id.uuidString == duplicate)
    }

    @Test func recentlyUsedKeepsPinAndManualOrders() throws {
        let (db, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let pinned = try db.capture(.text("置顶"), source: "Tests", policy: .standard)
        var item = try #require(db.list().first)
        item.pinned = true
        try db.update(item.id, group: item.group, favorite: item.favorite, pinned: item.pinned, queued: item.queued, queueOrder: item.queueOrder)
        let older = try db.capture(.text("旧"), source: "Tests", policy: .standard)
        _ = try db.capture(.text("新"), source: "Tests", policy: .standard)
        _ = try db.markUsed(older)
        #expect(try db.list().prefix(2).map(\.id) == [pinned, older])
        try db.reply(id: nil, title: "回复", text: "旧", group: "", policy: .standard)
        let reply = try #require(db.list().first { $0.reply })
        let used = try db.markUsed(reply.id)
        #expect(used.order == reply.order && used.queueOrder == reply.queueOrder)
        #expect(try db.list().count == 4)
    }

    @Test func importedDuplicatesMergeAndKeepFavorite() throws {
        let (first, root) = try store()
        let (second, otherRoot) = try store()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: otherRoot) }
        _ = try first.capture(.text("重复"), source: "A", policy: .standard)
        _ = try second.capture(.text("重复"), source: "B", policy: .standard)
        var favorite = try #require(first.list().first)
        favorite.favorite = true
        try first.update(favorite.id, favorite: true)
        let backup = otherRoot.appendingPathComponent("backup.json")
        try second.exportBackup(to: backup)
        try first.importBackup(from: backup, policy: .standard)
        #expect(try first.list().count == 1)
        #expect(try first.list().first?.favorite == true)
        #expect(try ClipboardStore(directory: root).list().count == 1)
    }

    @Test func backupAndQuotaAreTransactional() throws {
        let (db, root) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try db.capture(.text("protected"), source: "Tests", policy: .standard)
        var item = try #require(db.list().first)
        item.pinned = true
        try db.update(item.id, group: item.group, favorite: item.favorite, pinned: item.pinned, queued: item.queued, queueOrder: item.queueOrder)
        #expect(throws: (any Error).self) {
            try db.capture(.text(String(repeating: "x", count: 10000)), source: "Tests", policy: ClipPolicy(count: 100, days: 30, bytes: 100))
        }
        #expect(try db.list().map(\.id) == [id])
        try db.addGroup("工作")
        let backup = root.appendingPathComponent("backup.json")
        try db.exportBackup(to: backup)
        let (other, secondRoot) = try store()
        defer { try? FileManager.default.removeItem(at: secondRoot) }
        try other.importBackup(from: backup, policy: .standard)
        try other.importBackup(from: backup, policy: .standard)
        #expect(try other.list().count == 1)
        #expect(try other.groups() == ["工作"])
        try Data("bad".utf8).write(to: backup)
        #expect(throws: (any Error).self) { try other.importBackup(from: backup, policy: .standard) }
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
    @Test func imagePreviewIsDownsampled() throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4096, pixelsHigh: 2048,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let payload = ClipPayload(items: [["public.png": png]])
        let image = try #require(try payload.thumbnail())
        #expect(image.width == 1024 && image.height == 512)
        #expect(try ClipPayload.text("文本").thumbnail() == nil)
        #expect(throws: (any Error).self) { try ClipPayload(items: [["public.png": Data("bad".utf8)]]).thumbnail() }
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

@MainActor @Suite(.serialized) struct ClipboardInteractionTests {
    @Test func rowAgeUsesMinuteGranularity() {
        let now = Date(timeIntervalSince1970: 200000)
        for (seconds, text) in [(0.0, "刚刚"), (59, "刚刚"), (60, "1 分钟前"), (3600, "1 小时前"), (86400, "1 天前"), (-60, "刚刚")] {
            #expect(ClipboardRow.ageText(now.addingTimeInterval(-seconds), now: now) == text)
        }
    }

    @Test func visibleListTracksFiltersAndEdits() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let controller = ClipboardController(board: board)
        var first = ClipboardItem(kind: .text, preview: "甲", source: "Tests")
        first.group = "工作"; first.queued = true; first.queueOrder = 2
        var second = ClipboardItem(kind: .image, preview: "乙", source: "Tests")
        second.favorite = true; second.queued = true; second.queueOrder = 1
        controller.items = [first, second]
        #expect(controller.visible.map(\.id) == [first.id, second.id])
        controller.section = "堆栈"
        #expect(controller.visible.map(\.id) == [second.id, first.id])
        controller.group = "工作"
        #expect(controller.visible.map(\.id) == [first.id])
        controller.kind = "image"
        #expect(controller.visible.isEmpty)
        controller.group = ""; controller.section = "收藏"
        #expect(controller.visible.map(\.id) == [second.id])
        controller.items[1].favorite = false
        #expect(controller.visible.isEmpty)
        controller.kind = ""; controller.section = "全部"
        #expect(controller.visible.count == 2)
    }

    @Test func repeatedVisibleReadsBenchmark() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let controller = ClipboardController(board: board)
        controller.items = (0..<10000).map { ClipboardItem(kind: .text, preview: "合成记录 \($0)", source: "Tests") }
        let start = Date()
        var count = 0
        for _ in 0..<100 { count += controller.visible.count }
        print("VISIBLE_READS_100_MS=\(Date().timeIntervalSince(start) * 1000)")
        #expect(count == 1000000)
    }

    @Test func hidingReleasesDetail() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let db = try ClipboardStore(directory: root)
        let id = try db.capture(.text("详情"), source: "Tests", policy: .standard)
        let controller = ClipboardController(board: board, directory: root)
        controller.selected = id
        await controller.loadDetail()
        #expect(controller.detail != nil)
        controller.hide()
        #expect(controller.detail == nil)
        let pending = Task { await controller.loadDetail() }
        pending.cancel()
        await pending.value
        #expect(controller.detail == nil && controller.detailImage == nil)
        await controller.reload()
        #expect(controller.detail == nil)
    }

    @Test func cancelledReloadDoesNotReplaceVisibleItems() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let db = try ClipboardStore(directory: root)
        _ = try db.capture(.text("合成记录"), source: "Tests", policy: .standard)
        let controller = ClipboardController(board: board, directory: root)
        let pending = Task { await controller.reload() }
        pending.cancel()
        await pending.value
        #expect(controller.items.isEmpty)
        await controller.reload()
        #expect(controller.items.count == 1)
        controller.query = "不匹配"
        await controller.reload()
        #expect(controller.visible.isEmpty)
        controller.query = ""
        await controller.reload()
        #expect(controller.visible.count == 1)
    }

    @Test(arguments: ["", "-1", "3.5", "abc", "99", "10001"])
    func invalidHistoryLimit(_ input: String) {
        #expect(ClipboardController.validatedLimit(input, range: 100...10000) == nil)
    }
    @Test func manualLimits() {
        #expect(ClipboardController.validatedLimit(" 350 ", range: 100...10000) == 350)
        #expect(ClipboardController.validatedLimit("75", range: 20...1024) == 75)
        #expect(ClipboardController.validatedLimit("365", range: 1...365) == 365)
        #expect(ClipboardController.validatedLimit("366", range: 1...365) == nil)
    }
    @Test(arguments: [true, false]) func copyRespectsClosePreference(_ close: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ClipboardInteraction.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard.withUniqueName()
        let controller = ClipboardController(defaults: defaults, board: board, directory: root)
        defer { controller.hide(); board.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        #expect(controller.copyOnClick && controller.closeAfterAction)
        defaults.set(close, forKey: "clipCloseAfterAction")
        let db = try ClipboardStore(directory: root)
        let id = try db.capture(.text("合成拷贝测试"), source: "Tests", policy: .standard)
        _ = try db.capture(.text("更新的记录"), source: "Tests", policy: .standard)
        controller.show()
        controller.copy(id)
        let deadline = Date().addingTimeInterval(5)
        while controller.copying && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(board.string(forType: .string) == "合成拷贝测试")
        #expect(controller.isPanelVisible == !close)
        #expect(controller.items.first?.id == id)
        #expect(try ClipboardStore(directory: root).list().first?.id == id)
        controller.show()
        controller.copy(UUID())
        while controller.copying && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(controller.isPanelVisible)
        #expect(board.string(forType: .string) == "合成拷贝测试")
    }
}

@MainActor struct ClipboardLayoutTests {
    @Test func compactPanelRendersSyntheticContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "ClipboardLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard.withUniqueName()
        let db = try ClipboardStore(directory: root)
        defer { board.releaseGlobally(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        for text in ["周五前确认设计稿与开发排期", "https://example.com/design", "会议纪要.md", "项目资料已整理，请查收附件。这是一条用于检查长文本换行和操作按钮对齐的合成记录。"] {
            _ = try db.capture(.text(text), source: "示例内容", policy: .standard)
        }
        let controller = ClipboardController(defaults: defaults, board: board, directory: root)
        await controller.reload()
        for dark in [false, true] {
            for width in [480, 620] {
                let view = NSHostingView(rootView: ClipboardPanel(controller: controller))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 560), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = view
                view.frame = window.contentLayoutRect
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(150))
                view.layoutSubtreeIfNeeded()
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                #expect(view.bounds.width == CGFloat(width))
                try data.write(to: URL(fileURLWithPath: "/private/tmp/fastbudo-panel-\(dark ? "dark" : "light")-\(width).png"))
                window.orderOut(nil)
            }
        }
    }
}
