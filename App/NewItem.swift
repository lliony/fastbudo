import Foundation
import Darwin

/// 固定目标目录并排他创建，重名时保留原内容。
enum NewItem {
    static func create(in directory: URL, name: String, folder: Bool) throws -> URL {
        guard directory.isFileURL, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0"),
              name.utf8.count <= 240 else { throw CocoaError(.fileWriteInvalidFileName) }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(parent) }
        let suffix = folder ? "" : (name as NSString).pathExtension
        let stem = suffix.isEmpty ? name : (name as NSString).deletingPathExtension
        for number in 1...10000 {
            let candidate = number == 1 ? name : "\(stem) \(number)" + (suffix.isEmpty ? "" : ".\(suffix)")
            if folder {
                if mkdirat(parent, candidate, 0o755) == 0 { return directory.appendingPathComponent(candidate) }
            } else {
                let file = openat(parent, candidate, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
                if file >= 0 { Darwin.close(file); return directory.appendingPathComponent(candidate) }
            }
            let code = errno
            if code != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
        }
        throw CocoaError(.fileWriteFileExists)
    }
}
