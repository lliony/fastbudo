import AppKit

@MainActor final class ServicesProvider: NSObject {
    var receive: ([URL], ArchiveFormat) -> Void = { _, _ in }

    @objc func compress(_ board: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let userData, let format = ArchiveFormat(rawValue: userData) else {
            error.pointee = "不支持的压缩格式。"
            return
        }
        do { receive(try ServiceInput.urls(from: board), format) }
        catch _ { error.pointee = "请选择本地文件或文件夹。" }
    }
}
