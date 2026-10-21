import AppKit
import SwiftUI
import Carbon

@MainActor @Observable final class ClipboardController: NSObject, NSWindowDelegate {
    var items: [ClipboardItem] = [] { didSet { rebuildVisible() } }
    var groups: [String] = []
    var query = "" { didSet { rebuildVisible() } }
    var section = "全部" { didSet { rebuildVisible() } }
    var group = "" { didSet { rebuildVisible() } }
    var kind = "" { didSet { rebuildVisible() } }
    var selected: UUID?
    var detail: ClipPayload?
    var detailImage: CGImage?
    var showDetail = false
    private var detailGeneration = 0
    var message = "开启记录后，只收集新复制的内容。"
    var hotKeyMessage = ""
    var mode = ClipMode.original
    var loading = false
    private var matched = Set<UUID>() { didSet { rebuildVisible() } }
    private var reloadGeneration = 0
    private var db: ClipboardStore?
    private let directory: URL
    let defaults: UserDefaults
    private let board: NSPasteboard
    private let sourceInfo: () -> (bundle: String, name: String)
    private var lastChange: Int
    private var timer: Timer?
    private var captureInFlight = false
    private(set) var copying = false
    private var panel: NSPanel?
    private let hotKey = ClipboardHotKey()

    init(defaults: UserDefaults = .standard, board: NSPasteboard = .general, directory: URL? = nil,
         sourceInfo: @escaping () -> (bundle: String, name: String) = {
             let app = NSWorkspace.shared.frontmostApplication
             return (app?.bundleIdentifier ?? "", app?.localizedName ?? "未知应用")
         }) {
        self.defaults = defaults; self.board = board; self.sourceInfo = sourceInfo; lastChange = board.changeCount
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FastBudo/Clipboard", isDirectory: true)
        super.init()
    }
    var isPanelVisible: Bool { panel?.isVisible == true }
    var copyOnClick: Bool { defaults.object(forKey: "clipCopyOnClick") as? Bool ?? true }
    var closeAfterAction: Bool { defaults.object(forKey: "clipCloseAfterAction") as? Bool ?? true }
    /// 仅提交范围内的整数，编辑中的空值或无效字符不能改变清理策略。
    static func validatedLimit(_ text: String, range: ClosedRange<Int>) -> Int? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(value), range.contains(number) else { return nil }
        return number
    }
    var enabled: Bool { defaults.bool(forKey: "clipEnabled") }
    var policy: ClipPolicy {
        ClipPolicy(count: min(10000, max(1, defaults.object(forKey: "clipCount") as? Int ?? 1000)),
                   days: min(3650, max(1, defaults.object(forKey: "clipDays") as? Int ?? 30)),
                   bytes: min(1024, max(1, defaults.object(forKey: "clipMiB") as? Int ?? 200)) * 1024 * 1024)
    }
    var queue: [ClipboardItem] { items.filter(\.queued).sorted { $0.queueOrder < $1.queueOrder } }
    private(set) var visible: [ClipboardItem] = []
    // 仅数据或筛选条件改变时计算；滚动、选中和状态文字刷新复用结果。
    private func rebuildVisible() {
        let base = section == "堆栈" ? queue : section == "快捷回复" ? items.filter(\.reply).sorted { $0.order < $1.order } : items
        let query = query, group = group, kind = kind, section = section, matched = matched
        visible = base.filter {
            (query.isEmpty || matched.contains($0.id)) && (group.isEmpty || $0.group == group) && (kind.isEmpty || $0.kind.rawValue == kind) &&
            (section != "收藏" || $0.favorite) && (section != "历史" || !$0.reply)
        }
    }
    private func database() throws -> ClipboardStore {
        if let db { return db }
        let store = try ClipboardStore(directory: directory)
        db = store
        return store
    }
    func start() {
        guard timer == nil else { return }
        lastChange = board.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        configureShortcut()
    }
    func stop() {
        timer?.invalidate(); timer = nil; hotKey.stop()
    }
    func configureShortcut() {
        hotKey.stop()
        guard defaults.object(forKey: "clipHotKeyEnabled") as? Bool ?? true else { hotKeyMessage = "快捷键已关闭"; return }
        let key = UInt32(clamping: defaults.object(forKey: "clipHotKeyCode") as? Int ?? 9)
        let modifiers = UInt32(clamping: defaults.object(forKey: "clipHotKeyModifiers") as? Int ?? Int(controlKey | shiftKey))
        hotKey.action = { [weak self] in
            guard let self else { return }
            let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
            guard !self.excluded(app, key: "clipHotKeyExcluded") else { return }
            self.toggle()
        }
        hotKeyMessage = hotKey.register(key: key, modifiers: modifiers) ? "快捷键已注册" : "快捷键不可用或已被占用，请更换（需包含 Control 或 Command）。"
    }
    func setEnabled(_ value: Bool) {
        defaults.set(value, forKey: "clipEnabled")
        lastChange = board.changeCount
        message = value ? "正在记录新复制的内容" : "已暂停记录"
    }
    private func excluded(_ bundle: String, key: String) -> Bool {
        let fallback = key == "clipExcluded" ? "com.1password.1password, com.agilebits.onepassword7, com.apple.keychainaccess" : ""
        let list = defaults.string(forKey: key) ?? fallback
        return list.split(whereSeparator: { $0 == "," || $0 == "，" || $0.isWhitespace }).contains { $0 == bundle }
    }
    func poll() {
        guard board.changeCount != lastChange, !captureInFlight else { return }
        lastChange = board.changeCount
        guard enabled else { return }
        let source = sourceInfo()
        guard !excluded(source.bundle, key: "clipExcluded") else { return }
        do {
            guard let payload = try ClipboardCapture.read(board) else { return }
            let db = try database(), policy = policy, name = source.name
            captureInFlight = true
            Task {
                defer { captureInFlight = false }
                do {
                    _ = try await Task.detached { try db.capture(payload, source: name, policy: policy) }.value
                    await reload()
                    message = "已记录 · \(name)"
                } catch { message = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
    }
    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        do {
            let db = try database(), search = query
            let result = try await Task.detached {
                (try db.list(), try db.groups(), search.isEmpty ? Set<UUID>() : try db.matchingIDs(search))
            }.value
            guard !Task.isCancelled, generation == reloadGeneration, query == search else { return }
            items = result.0; groups = result.1
            if query == search { matched = result.2 }
            if selected == nil || !visible.contains(where: { $0.id == selected }) { selected = visible.first?.id }
        } catch { message = error.localizedDescription }
    }
    func clearDetail() {
        detailGeneration += 1; detail = nil; detailImage = nil
    }
    func loadDetail() async {
        clearDetail()
        let generation = detailGeneration
        guard let id = selected else { return }
        do {
            let db = try database()
            let result = try await Task.detached {
                let payload = try db.payload(id)
                let image = try payload.thumbnail()
                return (image == nil ? payload : nil, image)
            }.value
            guard !Task.isCancelled, generation == detailGeneration, selected == id else { return }
            detail = result.0; detailImage = result.1
        } catch { message = error.localizedDescription }
    }
    func work(_ operation: @escaping @Sendable (ClipboardStore) throws -> Void, onSuccess: @escaping () -> Void = {}) {
        guard !loading else { return }
        do {
            let db = try database()
            loading = true
            Task {
                defer { loading = false }
                do {
                    try await Task.detached { try operation(db) }.value
                    await reload(); message = "操作已完成"; onSuccess()
                } catch { message = error.localizedDescription }
            }
        } catch { message = error.localizedDescription }
    }
    func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "删除 \(ids.count) 条剪贴板记录？"
        alert.informativeText = "此操作不会删除原始文件，记录删除后无法撤销。"
        alert.addButton(withTitle: "删除"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { work { try $0.delete(ids) } }
    }
    func enqueue(_ item: ClipboardItem) { work { try $0.update(item.id, queued: !item.queued, queueOrder: Date().timeIntervalSince1970) } }
    func reverseQueue() {
        let reversed = Array(queue.reversed())
        work { store in for (index, item) in reversed.enumerated() { try store.update(item.id, queueOrder: Double(index)) } }
    }
    func moveReply(_ item: ClipboardItem, by delta: Int) {
        let replies = items.filter(\.reply).sorted { $0.order < $1.order }
        guard let index = replies.firstIndex(where: { $0.id == item.id }), replies.indices.contains(index + delta) else { return }
        var first = item, second = replies[index + delta]
        swap(&first.order, &second.order)
        let a = first, b = second
        work { try $0.update(a.id, order: a.order); try $0.update(b.id, order: b.order) }
    }
    func toggle() { if panel?.isVisible == true { hide() } else { show() } }
    func show() {
        if panel == nil {
            let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "FastBudo 剪贴板"
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.minSize = NSSize(width: 480, height: 400)
            window.contentViewController = NSHostingController(rootView: ClipboardPanel(controller: self))
            window.center(); window.setFrameAutosaveName("FastBudoClipboardCompact")
            panel = window
        }
        panel?.makeKeyAndOrderFront(nil); NSApp.activate()
        Task { await reload() }
    }
    func hide() { showDetail = false; clearDetail(); panel?.orderOut(nil) }
    func windowWillClose(_ notification: Notification) { showDetail = false; clearDetail() }
    /// 所有拷贝入口共用完成逻辑；失败时不关闭面板，也不再发送粘贴按键。
    func copy(_ id: UUID) {
        guard !copying else { return }
        copying = true
        let mode = mode
        Task {
            defer { copying = false }
            do {
                let db = try database()
                let payload = try await Task.detached { try db.payload(id) }.value
                try ClipboardCapture.write(payload, to: board, mode: mode)
                lastChange = board.changeCount
                let updated = try await Task.detached { try db.markUsed(id) }.value
                if let index = items.firstIndex(where: { $0.id == id }) {
                    items.remove(at: index)
                    let destination = items.firstIndex {
                        updated.pinned != $0.pinned ? updated.pinned : updated.used > $0.used
                    } ?? items.endIndex
                    items.insert(updated, at: destination)
                }
                message = "已拷贝"
                if closeAfterAction { hide() }
            } catch { message = error.localizedDescription }
        }
    }
    func exportBackup() {
        let save = NSSavePanel(); save.nameFieldStringValue = "FastBudo-剪贴板.json"; save.allowedContentTypes = [.json]
        guard save.runModal() == .OK, let url = save.url else { return }
        work { db in
            try db.exportBackup(to: url)
        }
    }
    func importBackup() {
        let open = NSOpenPanel(); open.allowedContentTypes = [.json]
        guard open.runModal() == .OK, let url = open.url else { return }
        let policy = policy
        work { db in
            try db.importBackup(from: url, policy: policy)
        }
    }
}
