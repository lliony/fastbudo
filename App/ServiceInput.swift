import AppKit

enum ServiceInput {
    enum InputError: Error { case noFiles }

    // 系统剪贴板属于输入边界；不让无效服务请求进入任务队列。
    @MainActor static func urls(from board: NSPasteboard) throws -> [URL] {
        guard let objects = board.readObjects(forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]) as? [URL], !objects.isEmpty else {
            throw InputError.noFiles
        }
        var seen = Set<URL>()
        return objects.filter { $0.isFileURL && seen.insert($0).inserted }
    }
}
