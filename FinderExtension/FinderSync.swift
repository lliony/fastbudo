import Cocoa
import FinderSync

final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(updateTypes(_:)),
            name: NewItemTypes.changed, object: nil, suspensionBehavior: .deliverImmediately)
        DistributedNotificationCenter.default().postNotificationName(NewItemTypes.requested,
            object: nil, userInfo: nil, deliverImmediately: true)
        // 仅提供菜单，不枚举目录或读取文件；覆盖本地及挂载卷中的选择。
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    // 沙箱扩展只接收经过校验的后缀列表，不接收路径或执行指令。
    @objc private func updateTypes(_ notification: Notification) {
        guard let text = notification.object as? String, text.utf8.count <= 1024 else { return }
        NewItemTypes.defaults.set(NewItemTypes.parse(text).joined(separator: ", "), forKey: NewItemTypes.key)
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else { return nil }
        let menu = NSMenu()
        let controller = FIFinderSyncController.default()
        let selection = controller.selectedItemURLs() ?? []
        let directory = menuKind == .contextualMenuForContainer
            ? controller.targetedURL() : FinderRequest.creationDirectory(for: selection)
        if let directory, directory.isFileURL {
            let parent = NSMenuItem(title: "FastBudo 新建", action: nil, keyEquivalent: "")
            let children = NSMenu()
            for type in ["folder"] + NewItemTypes.current + ["custom"] {
                let title = type == "folder" ? "文件夹" : type == "custom" ? "自定义文件…" : "\(type.uppercased()) 文件"
                let item = NSMenuItem(title: title, action: #selector(createItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["type": type, "directory": directory.absoluteString]
                children.addItem(item)
            }
            parent.submenu = children
            menu.addItem(parent)
        }
        guard menuKind == .contextualMenuForItems, !selection.isEmpty else { return menu.items.isEmpty ? nil : menu }
        let parent = NSMenuItem(title: "FastBudo 压缩", action: nil, keyEquivalent: "")
        let formats = NSMenu()
        for format in FinderRequest.formats {
            let item = NSMenuItem(title: format.uppercased(), action: #selector(compress(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = format
            formats.addItem(item)
        }
        parent.submenu = formats
        menu.addItem(parent)
        return menu
    }

    @objc private func compress(_ sender: NSMenuItem) {
        guard let format = sender.representedObject as? String,
              let files = FIFinderSyncController.default().selectedItemURLs(), !files.isEmpty else { return }
        send(files, value: format, action: "compress")
    }

    @objc private func createItem(_ sender: NSMenuItem) {
        guard let values = sender.representedObject as? [String: String],
              let type = values["type"], let path = values["directory"],
              let directory = URL(string: path), directory.isFileURL else { return }
        send([directory], value: type, action: "create")
    }

    private func send(_ files: [URL], value: String, action: String) {
        let board = NSPasteboard.withUniqueName()
        guard board.writeObjects(files.map { $0 as NSURL }),
              let request = FinderRequest.url(board: board.name.rawValue, format: value, action: action) else {
            board.releaseGlobally()
            return
        }
        // 明确打开包含此扩展的应用，避免同名 URL scheme 被其他应用抢占。
        let app = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        let boardName = board.name.rawValue
        NSWorkspace.shared.open([request], withApplicationAt: app, configuration: configuration) { _, error in
            if error != nil { NSPasteboard(name: NSPasteboard.Name(boardName)).releaseGlobally() }
        }
    }
}
