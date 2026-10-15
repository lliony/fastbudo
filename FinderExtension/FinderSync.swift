import Cocoa
import FinderSync

final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        // 仅提供菜单，不枚举目录或读取文件；覆盖本地及挂载卷中的选择。
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let urls = FIFinderSyncController.default().selectedItemURLs(), !urls.isEmpty else { return nil }
        let menu = NSMenu()
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
        let board = NSPasteboard.withUniqueName()
        guard board.writeObjects(files.map { $0 as NSURL }),
              let request = FinderRequest.url(board: board.name.rawValue, format: format) else {
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
