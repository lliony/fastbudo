import AppKit

@MainActor final class ServicesProvider: NSObject {
    var receive: ([URL], String) -> Void = { _, _ in }

    @objc func quickZip(_ board: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        accept(board, action: "快捷 ZIP", error: error)
    }

    @objc func moreOptions(_ board: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        accept(board, action: "更多压缩选项", error: error)
    }

    private func accept(_ board: NSPasteboard, action: String, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        do { receive(try ServiceInput.urls(from: board), action) }
        catch _ { error.pointee = "请选择本地文件或文件夹。" }
    }
}
