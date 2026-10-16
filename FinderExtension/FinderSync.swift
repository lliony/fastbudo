import Cocoa
import FinderSync

final class FinderSync: FIFinderSync {
    private var nextCommand = 0
    private var commands: [Int: (files: [URL], value: String, action: String)] = [:]

    // Finder 转发菜单项时不能依赖 representedObject；用 tag 查找扩展内的请求快照。
    private func commandItem(title: String, files: [URL], value: String, action: String) -> NSMenuItem {
        nextCommand += 1
        let item = NSMenuItem(title: title, action: #selector(executeCommand(_:)), keyEquivalent: "")
        item.target = self
        item.tag = nextCommand
        commands[item.tag] = (files, value, action)
        return item
    }

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
        commands.removeAll()
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
                let item = commandItem(title: title, files: [directory], value: type, action: "create")
                children.addItem(item)
            }
            parent.submenu = children
            menu.addItem(parent)
        }
        guard menuKind == .contextualMenuForItems, !selection.isEmpty else { return menu.items.isEmpty ? nil : menu }
        let parent = NSMenuItem(title: "FastBudo 压缩", action: nil, keyEquivalent: "")
        let formats = NSMenu()
        for format in FinderRequest.formats {
            let item = commandItem(title: format.uppercased(), files: selection, value: format, action: "compress")
            formats.addItem(item)
        }
        parent.submenu = formats
        menu.addItem(parent)
        return menu
    }

    @objc private func executeCommand(_ sender: NSMenuItem) {
        guard let command = commands.removeValue(forKey: sender.tag) else { return }
        send(command.files, value: command.value, action: command.action)
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
