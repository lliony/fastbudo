import AppKit

/// 只通过专用剪贴板传递本地选择，URL 不携带文件路径或密码。
enum FinderRequest {
    static let formats = ["zip", "7z", "tar.gz"]
    enum Invalid: Error { case request }

    static func url(board: String, format: String, action: String = "compress") -> URL? {
        guard valid(action: action, value: format), !board.isEmpty, board.utf8.count <= 256 else { return nil }
        var components = URLComponents()
        components.scheme = "fastbudo"
        components.host = action
        components.queryItems = [URLQueryItem(name: "board", value: board), URLQueryItem(name: "format", value: format)]
        return components.url
    }

    /// 在选择项旁边新建；搜索结果跨目录时不猜测目标位置。
    static func creationDirectory(for selection: [URL]) -> URL? {
        guard let first = selection.first, selection.allSatisfy({ $0.isFileURL }) else { return nil }
        let parent = first.deletingLastPathComponent().standardizedFileURL
        return selection.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == parent } ? parent : nil
    }

    private static func valid(action: String, value: String) -> Bool {
        if action == "compress" { return formats.contains(value) }
        return action == "create" && (value == "folder" || value == "custom" || NewItemTypes.parse(value) == [value])
    }

    @MainActor static func read(_ url: URL) throws -> (files: [URL], format: String, action: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "fastbudo", let action = components.host,
              components.path.isEmpty, components.user == nil, components.password == nil,
              components.port == nil, components.fragment == nil,
              let items = components.queryItems, items.count == 2,
              items.filter({ $0.name == "board" }).count == 1,
              items.filter({ $0.name == "format" }).count == 1,
              let name = items.first(where: { $0.name == "board" })?.value,
              let format = items.first(where: { $0.name == "format" })?.value,
              self.url(board: name, format: format, action: action) != nil else { throw Invalid.request }
        let board = NSPasteboard(name: NSPasteboard.Name(name))
        guard let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !files.isEmpty, files.allSatisfy({ $0.isFileURL && $0.host.map { $0.isEmpty || $0 == "localhost" } != false }) else {
            throw Invalid.request
        }
        var seen = Set<URL>()
        guard action != "create" || files.count == 1 else { throw Invalid.request }
        return (files.filter { seen.insert($0).inserted }, format, action)
    }
}
