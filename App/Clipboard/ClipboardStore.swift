import Foundation
import SQLite3
import CryptoKit

/// 所有数据库访问串行化；元数据和原始表示在同一事务中提交。
final class ClipboardStore: @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private enum Value { case text(String), blob(Data) }
    private struct Backup: Codable { var version = 1; var groups: [String]; var records: [Record] }
    private struct Record: Codable { var item: ClipboardItem; var payload: ClipPayload }

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("clipboard.sqlite")
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }; db = nil; throw ClipError.storage
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let version = try statement("PRAGMA user_version")
            let schema = sqlite3_step(version) == SQLITE_ROW ? sqlite3_column_int(version, 0) : -1
            let supported = schema >= 0 && schema <= 2
            sqlite3_finalize(version)
            guard supported else { throw ClipError.storage }
            sqlite3_busy_timeout(db, 3000)
            try exec("PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS clips (id TEXT PRIMARY KEY, meta BLOB NOT NULL, payload BLOB NOT NULL, hash TEXT NOT NULL, search TEXT NOT NULL, bytes INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS clip_hash ON clips(hash); CREATE TABLE IF NOT EXISTS groups (name TEXT PRIMARY KEY); ")
            if schema < 2 {
                try transaction { try deduplicate(); try exec("PRAGMA user_version=2") }
            }
        } catch { sqlite3_close(db); db = nil; throw error }
    }
    deinit { sqlite3_close(db) }
    private func exec(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ClipError.storage } }
    private func statement(_ sql: String, _ values: [Value] = []) throws -> OpaquePointer {
        var result: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &result, nil) == SQLITE_OK, let result else { throw ClipError.storage }
        for (index, value) in values.enumerated() {
            let code: Int32
            switch value {
            case .text(let text): code = sqlite3_bind_text(result, Int32(index + 1), text, -1, transient)
            case .blob(let data): code = data.withUnsafeBytes { sqlite3_bind_blob(result, Int32(index + 1), $0.baseAddress, Int32(data.count), transient) }
            }
            if code != SQLITE_OK { sqlite3_finalize(result); throw ClipError.storage }
        }
        return result
    }
    private func run(_ sql: String, _ values: [Value] = []) throws {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw ClipError.storage }
    }
    private func blob(_ stmt: OpaquePointer, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
    }
    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do { let result = try body(); try exec("COMMIT"); return result }
        catch { try? exec("ROLLBACK"); throw error }
    }
    private func records(_ query: String = "") throws -> [ClipboardItem] {
        // instr treats %, _ and quotes literally rather than as SQL patterns.
        let stmt = try query.isEmpty ? statement("SELECT meta FROM clips") : statement("SELECT meta FROM clips WHERE instr(lower(search),lower(?))>0", [.text(query)])
        defer { sqlite3_finalize(stmt) }
        var items: [ClipboardItem] = []
        var code = sqlite3_step(stmt)
        while code == SQLITE_ROW {
            items.append(try JSONDecoder().decode(ClipboardItem.self, from: blob(stmt, 0)))
            code = sqlite3_step(stmt)
        }
        guard code == SQLITE_DONE else { throw ClipError.storage }
        return items.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.used > $1.used }
    }
    func list(query: String = "") throws -> [ClipboardItem] { try lock.withLock { try records(query) } }
    private func content(_ id: UUID) throws -> ClipPayload {
        let stmt = try statement("SELECT payload FROM clips WHERE id=?", [.text(id.uuidString)])
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw ClipError.invalid }
        return try JSONDecoder().decode(ClipPayload.self, from: blob(stmt, 0))
    }
    func payload(_ id: UUID) throws -> ClipPayload { try lock.withLock { try content(id) } }
    // 只改元数据和计费长度，不读取或重写可能达 20 MiB 的内容。
    private func putMetadata(_ item: ClipboardItem, previousTitle: String? = nil) throws {
        let meta = try JSONEncoder().encode(item)
        try run("UPDATE clips SET bytes=bytes-length(meta)+?, meta=? WHERE id=?",
                [.text(String(meta.count)), .blob(meta), .text(item.id.uuidString)])
        if let previousTitle, previousTitle != item.title {
            try run("UPDATE clips SET search=? || substr(search,length(?)+1), bytes=bytes+? WHERE id=?",
                    [.text(item.title), .text(previousTitle), .text(String(item.title.utf8.count - previousTitle.utf8.count)), .text(item.id.uuidString)])
        }
    }
    /// 成功拷贝后持久化最近使用时间，返回更新后的单条元数据。
    func markUsed(_ id: UUID) throws -> ClipboardItem {
        try lock.withLock { try transaction {
            let stmt = try statement("SELECT meta FROM clips WHERE id=?", [.text(id.uuidString)])
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw ClipError.invalid }
            var item = try JSONDecoder().decode(ClipboardItem.self, from: blob(stmt, 0))
            item.used = Date()
            try putMetadata(item)
            return item
        } }
    }
    // 迁移和导入时按哈希逐组处理；不把所有历史的图片、富文本载入内存。
    private func deduplicate() throws {
        let hashes = try statement("SELECT hash FROM clips GROUP BY hash HAVING count(*)>1")
        var values: [String] = []
        var code = sqlite3_step(hashes)
        while code == SQLITE_ROW {
            values.append(String(cString: sqlite3_column_text(hashes, 0)))
            code = sqlite3_step(hashes)
        }
        sqlite3_finalize(hashes)
        guard code == SQLITE_DONE else { throw ClipError.storage }
        for hash in values {
            let stmt = try statement("SELECT meta FROM clips WHERE hash=?", [.text(hash)])
            var items: [ClipboardItem] = []
            do {
                var code = sqlite3_step(stmt)
                while code == SQLITE_ROW {
                    let item = try JSONDecoder().decode(ClipboardItem.self, from: blob(stmt, 0))
                    if !item.reply { items.append(item) }
                    code = sqlite3_step(stmt)
                }
                guard code == SQLITE_DONE else { throw ClipError.storage }
            } catch { sqlite3_finalize(stmt); throw error }
            sqlite3_finalize(stmt)
            items.sort { $0.used > $1.used }
            guard items.count > 1, var keep = items.first else { continue }
            let title = keep.title
            for old in items.dropFirst() {
                keep.favorite = keep.favorite || old.favorite
                keep.pinned = keep.pinned || old.pinned
                if old.queued && (!keep.queued || old.queueOrder < keep.queueOrder) { keep.queueOrder = old.queueOrder }
                keep.queued = keep.queued || old.queued
                if keep.title.isEmpty { keep.title = old.title }
                if keep.group.isEmpty { keep.group = old.group }
                keep.created = min(keep.created, old.created)
                try run("DELETE FROM clips WHERE id=?", [.text(old.id.uuidString)])
            }
            try putMetadata(keep, previousTitle: title)
        }
    }
    private func put(_ item: ClipboardItem, _ payload: ClipPayload) throws {
        try payload.validate()
        guard item.title.count <= 1000, item.group.count <= 80, item.source.count <= 300 else { throw ClipError.invalid }
        if !item.group.isEmpty { try run("INSERT OR IGNORE INTO groups VALUES(?)", [.text(item.group)]) }
        let data = try payload.encoded()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let meta = try JSONEncoder().encode(item)
        let search = item.title + "\n" + payload.searchText
        try run("INSERT OR REPLACE INTO clips VALUES(?,?,?,?,?,?)", [.text(item.id.uuidString), .blob(meta), .blob(data), .text(hash), .text(search), .text(String(data.count + meta.count + search.utf8.count))])
    }
    private func prune(_ policy: ClipPolicy, excluding id: UUID? = nil) throws {
        guard policy.count > 0, policy.days > 0, policy.bytes > 0 else { throw ClipError.invalid }
        let stmt = try statement("SELECT meta, bytes FROM clips")
        var candidates: [(item: ClipboardItem, bytes: Int)] = []
        var total = 0, count = 0, ordinaryCount = 0
        do {
            var code = sqlite3_step(stmt)
            while code == SQLITE_ROW {
                let item = try JSONDecoder().decode(ClipboardItem.self, from: blob(stmt, 0))
                let bytes = Int(sqlite3_column_int64(stmt, 1))
                total += bytes; count += 1
                if !item.protected {
                    ordinaryCount += 1
                    if item.id != id { candidates.append((item, bytes)) }
                }
                code = sqlite3_step(stmt)
            }
            guard code == SQLITE_DONE else { throw ClipError.storage }
        } catch { sqlite3_finalize(stmt); throw error }
        sqlite3_finalize(stmt)
        candidates.sort { $0.item.used < $1.item.used }
        let cutoff = Date().addingTimeInterval(-Double(policy.days) * 86400)
        // 一次扫描计费，删除时扣减；避免每淘汰一条都重新扫描整个数据库。
        for candidate in candidates where candidate.item.used < cutoff || ordinaryCount > policy.count || total > policy.bytes {
            try run("DELETE FROM clips WHERE id=?", [.text(candidate.item.id.uuidString)])
            total -= candidate.bytes; count -= 1; ordinaryCount -= 1
        }
        if total > policy.bytes || count > 10000 { throw ClipError.full }
    }
    func capture(_ payload: ClipPayload, source: String, policy: ClipPolicy) throws -> UUID {
        try lock.withLock {
            try transaction {
                try payload.validate()
                guard source.count <= 300 else { throw ClipError.invalid }
                let hash = SHA256.hash(data: try payload.encoded()).map { String(format: "%02x", $0) }.joined()
                let stmt = try statement("SELECT meta FROM clips WHERE hash=?", [.text(hash)])
                defer { sqlite3_finalize(stmt) }
                var item = ClipboardItem(kind: payload.kind, preview: payload.preview, source: source)
                var existing = false
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let old = try JSONDecoder().decode(ClipboardItem.self, from: blob(stmt, 0))
                    if !old.reply { item = old; existing = true; break }
                }
                item.used = Date(); item.source = source
                if existing { try putMetadata(item) } else { try put(item, payload) }
                try prune(policy, excluding: item.id)
                return item.id
            }
        }
    }
    /// 只提交用户编辑的字段，避免旧界面快照覆盖最近使用时间及其他并发更新。
    func update(_ id: UUID, title: String? = nil, group: String? = nil, favorite: Bool? = nil,
                pinned: Bool? = nil, queued: Bool? = nil, order: Double? = nil, queueOrder: Double? = nil) throws {
        try lock.withLock { try transaction {
            let stmt = try statement("SELECT meta FROM clips WHERE id=?", [.text(id.uuidString)])
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { throw ClipError.invalid }
            var item = try JSONDecoder().decode(ClipboardItem.self, from: blob(stmt, 0))
            let oldTitle = item.title
            if let title { item.title = title }
            if let group { item.group = group }
            if let favorite { item.favorite = favorite }
            if let pinned { item.pinned = pinned }
            if let queued { item.queued = queued }
            if let order { item.order = order }
            if let queueOrder { item.queueOrder = queueOrder }
            guard item.title.count <= 1000, item.group.count <= 80,
                  item.order.isFinite, item.queueOrder.isFinite else { throw ClipError.invalid }
            if !item.group.isEmpty { try run("INSERT OR IGNORE INTO groups VALUES(?)", [.text(item.group)]) }
            try putMetadata(item, previousTitle: oldTitle)
        } }
    }
    func matchingIDs(_ query: String) throws -> Set<UUID> { try lock.withLock {
        let stmt = try statement("SELECT id FROM clips WHERE instr(lower(search),lower(?))>0", [.text(query)])
        defer { sqlite3_finalize(stmt) }
        var ids = Set<UUID>()
        var code = sqlite3_step(stmt)
        while code == SQLITE_ROW {
            guard let id = UUID(uuidString: String(cString: sqlite3_column_text(stmt, 0))) else { throw ClipError.storage }
            ids.insert(id); code = sqlite3_step(stmt)
        }
        guard code == SQLITE_DONE else { throw ClipError.storage }
        return ids
    } }

    func reply(id: UUID?, title: String, text: String, group: String, policy: ClipPolicy) throws {
        try lock.withLock { try transaction {
            guard !text.isEmpty else { throw ClipError.invalid }
            var item = try id.flatMap { id in try records().first { $0.id == id } } ?? ClipboardItem(kind: .text, preview: String(text.prefix(500)), source: "快捷回复")
            item.reply = true; item.title = title; item.group = group; item.preview = String(text.prefix(500)); item.used = Date()
            try put(item, .text(text)); try prune(policy, excluding: item.id)
        } }
    }
    func delete(_ ids: Set<UUID>) throws { try lock.withLock { try transaction {
        for id in ids { try run("DELETE FROM clips WHERE id=?", [.text(id.uuidString)]) }
    } } }
    func clean(_ policy: ClipPolicy) throws { try lock.withLock { try transaction { try prune(policy) }; try exec("VACUUM") } }
    func groups() throws -> [String] { try lock.withLock { try groupNames() } }
    private func groupNames() throws -> [String] {
        let stmt = try statement("SELECT name FROM groups ORDER BY name"); defer { sqlite3_finalize(stmt) }
        var values: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW { values.append(String(cString: sqlite3_column_text(stmt, 0))) }
        return values
    }
    func addGroup(_ name: String) throws { try lock.withLock {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 80 else { throw ClipError.invalid }
        try run("INSERT OR IGNORE INTO groups VALUES(?)", [.text(value)])
    } }
    func deleteGroup(_ name: String) throws { try lock.withLock { try transaction {
        for var item in try records() where item.group == name { item.group = ""; try putMetadata(item) }
        try run("DELETE FROM groups WHERE name=?", [.text(name)])
    } } }
    func exportData() throws -> Data { try lock.withLock {
        let records = try records().map { Record(item: $0, payload: try content($0.id)) }
        return try JSONEncoder().encode(Backup(groups: groupNames(), records: records))
    } }
    func importData(_ data: Data, policy: ClipPolicy) throws {
        guard data.count <= 300 * 1024 * 1024 else { throw ClipError.tooLarge }
        let backup = try JSONDecoder().decode(Backup.self, from: data)
        guard backup.version == 1, backup.records.count <= 10000, backup.groups.count <= 1000, Set(backup.records.map { $0.item.id }).count == backup.records.count else { throw ClipError.invalid }
        try lock.withLock { try transaction {
            let ids = Set(try records().map(\.id))
            for name in backup.groups {
                guard !name.isEmpty, name.count <= 80 else { throw ClipError.invalid }
                try run("INSERT OR IGNORE INTO groups VALUES(?)", [.text(name)])
            }
            for record in backup.records where !ids.contains(record.item.id) {
                var item = record.item
                try record.payload.validate()
                item.kind = record.payload.kind; item.preview = record.payload.preview
                guard item.created.timeIntervalSince1970.isFinite, item.used.timeIntervalSince1970.isFinite, item.order.isFinite else { throw ClipError.invalid }
                try put(item, record.payload)
            }
            try deduplicate()
            try prune(policy)
        } }
    }
}
