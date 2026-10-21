import Darwin
import Foundation

enum ArchiveFormat: String, CaseIterable, Sendable { case zip, sevenZip = "7z", tarGz = "tar.gz" }
struct CreateRequest: Sendable {
    var inputs: [URL]
    var outputDirectory: URL
    var name: String
    var format: ArchiveFormat = .zip
    var excludeDSStore = true
    var preserveAttributes = false
}
struct ArchiveFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

// 每个任务独享一个执行器；锁仅保护进程生命周期，文件操作在后台进行。
final class ArchiveEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private let resources: URL
    private let progress: @Sendable (String) -> Void
    private static let workspaceLock = NSLock()

    init(resources: URL = Bundle.main.resourceURL!, progress: @escaping @Sendable (String) -> Void = { _ in }) {
        self.resources = resources
        self.progress = progress
    }
    private static func recordWorkspace(_ url: URL, active: Bool) {
        workspaceLock.withLock {
            var paths = UserDefaults.standard.stringArray(forKey: "unfinishedWorkspaces") ?? []
            paths.removeAll { $0 == url.path }
            if active { paths.append(url.path) }
            UserDefaults.standard.set(paths, forKey: "unfinishedWorkspaces")
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let process, process.isRunning { process.terminate() }
        }
    }
    private func checkCancellation() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }

    private func run(_ executable: URL, _ arguments: [String], at directory: URL, input: String = "") throws -> Data {
        try checkCancellation()
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = directory
        let output = Pipe(), secret = Pipe()
        child.standardOutput = output
        child.standardError = output
        child.standardInput = secret
        try lock.withLock {
            if cancelled { throw CancellationError() }
            try child.run()
            process = child
        }
        defer { lock.withLock { process = nil } }
        do {
            try secret.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try secret.fileHandleForWriting.close()
            var data = Data()
            while let chunk = try output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
                guard data.count + chunk.count <= 64 * 1024 * 1024 else {
                    child.terminate()
                    throw ArchiveFailure("引擎输出超过内存限制，已终止任务。")
                }
                data.append(chunk)
            }
            child.waitUntilExit()
            try checkCancellation()
            guard child.terminationStatus == 0 else {
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let code = object["error"] as? String { throw ArchiveFailure(code) }
                throw ArchiveFailure("压缩引擎执行失败（\(child.terminationStatus)），请检查文件权限、空间或密码。")
            }
            return data
        } catch {
            try? secret.fileHandleForWriting.close()
            if child.isRunning { child.terminate() }
            child.waitUntilExit()
            throw error
        }
    }

    private func withWorkspace(parent: URL, body: (URL) throws -> URL) throws -> URL {
        let workspace = parent.appendingPathComponent(".fastbudo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        Self.recordWorkspace(workspace, active: true)
        do {
            let output = try body(workspace)
            do { try FileManager.default.removeItem(at: workspace) }
            catch { throw ArchiveFailure("结果已生成：\(output.path)。临时目录清理失败：\(workspace.path)") }
            Self.recordWorkspace(workspace, active: false)
            return output
        } catch {
            let original = error
            if FileManager.default.fileExists(atPath: workspace.path) {
                do { try FileManager.default.removeItem(at: workspace) }
                catch { throw ArchiveFailure("\(original.localizedDescription)；临时目录未清理：\(workspace.path)") }
            }
            Self.recordWorkspace(workspace, active: false)
            throw original
        }
    }

    func create(_ request: CreateRequest, password: String = "") throws -> URL {
        guard !request.name.isEmpty, request.name != ".", request.name != "..",
              !request.name.contains("/"), !request.name.contains("\0") else { throw ArchiveFailure("请输入有效文件名。") }
        guard password.utf8.count <= 4096, !password.contains("\n"), !password.contains("\r") else {
            throw ArchiveFailure("密码不能包含换行，长度不能超过 4096 字节。")
        }
        guard request.format != .tarGz || password.isEmpty else { throw ArchiveFailure("tar.gz 不支持密码。") }
        guard !request.preserveAttributes || (request.format == .zip && password.isEmpty) else {
            throw ArchiveFailure("保留 Mac 属性目前仅支持无密码 ZIP。")
        }
        return try withWorkspace(parent: request.outputDirectory) { workspace in
            progress("正在整理文件与元数据…")
            let stage = workspace.appendingPathComponent("input")
            try ArchiveFiles.stage(request.inputs, into: stage, excludeDSStore: request.excludeDSStore,
                                   preserveAttributes: request.preserveAttributes, checkCancellation: self.checkCancellation)
            progress("正在压缩为 " + request.format.rawValue.uppercased() + "…")
            let archive = workspace.appendingPathComponent("result." + request.format.rawValue)
            let cli = resources.appendingPathComponent("7zz")
            var flags = ["a", "-y", "-bd", "-bb0"]
            var secret = ""
            if !password.isEmpty {
                flags += ["-p"]
                flags += request.format == .zip ? ["-mem=AES256"] : ["-mhe=on"]
                secret = password + "\n" + password + "\n"
            }
            if request.preserveAttributes {
                _ = try run(URL(fileURLWithPath: "/usr/bin/ditto"), ["-c", "-k", "--sequesterRsrc", stage.path, archive.path], at: workspace)
            } else if request.format == .tarGz {
                let tar = workspace.appendingPathComponent("payload.tar")
                _ = try run(cli, flags + ["-ttar", tar.path, "--", "."], at: stage)
                _ = try run(cli, flags + ["-tgzip", archive.path, "--", tar.lastPathComponent], at: workspace)
            } else {
                _ = try run(cli, flags + ["-t" + request.format.rawValue, archive.path, "--", "."], at: stage, input: secret)
            }
            try checkCancellation()
            return try ArchiveFiles.commit(archive, to: request.outputDirectory.appendingPathComponent(request.name + "." + request.format.rawValue))
        }
    }

    func extract(_ input: URL, to directory: URL, password: String = "", approved: Bool = false) throws -> URL {
        try withWorkspace(parent: directory) { workspace in
            progress("正在准备归档快照…")
            // 同一份快照用于预检与解压，外部修改原包不能改变已检查的输入。
            let snapshot = workspace.appendingPathComponent("archive")
            let filename = input.lastPathComponent
            func family(_ name: String) -> String {
                var value = name.replacingOccurrences(of: "(?i)\\.part[0-9]+\\.rar$", with: ".rar", options: .regularExpression)
                value = value.replacingOccurrences(of: "(?i)\\.r[0-9]+$", with: ".rar", options: .regularExpression)
                value = value.replacingOccurrences(of: "(?i)\\.z[0-9]+$", with: ".zip", options: .regularExpression)
                return value.replacingOccurrences(of: "\\.[0-9]{3,}$", with: "", options: .regularExpression)
            }
            let targetFamily = family(filename)
            let related = try ArchiveFiles.children(input.deletingLastPathComponent()).filter {
                $0.lastPathComponent == filename || family($0.lastPathComponent) == targetFamily
            }
            try ArchiveFiles.stage(related, into: snapshot, excludeDSStore: false, preserveAttributes: false,
                                   checkCancellation: self.checkCancellation)
            let stableInput = snapshot.appendingPathComponent(filename)
            progress("正在检查并解压归档…")
            let output = workspace.appendingPathComponent("output")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let helper = resources.appendingPathComponent("ArchiveBridge")
            let library = resources.appendingPathComponent("7z.so")
            func extractInto(_ source: URL, _ destination: URL) throws {
                var args = [library.path, source.path, destination.path]
                if approved { args.append("--approved") }
                _ = try run(helper, args, at: workspace, input: password)
            }
            let lower = input.lastPathComponent.lowercased()
            if lower.hasSuffix(".tar.gz") || lower.hasSuffix(".tgz") {
                let wrapper = workspace.appendingPathComponent("gzip")
                try FileManager.default.createDirectory(at: wrapper, withIntermediateDirectories: false)
                try extractInto(stableInput, wrapper)
                let files = try ArchiveFiles.children(wrapper)
                guard files.count == 1 else { throw ArchiveFailure("无效的 tar.gz 归档。") }
                try extractInto(files[0], output)
            } else { try extractInto(stableInput, output) }
            progress("正在恢复属性并保存结果…")
            try restoreAppleDouble(in: output)
            try propagateQuarantine(from: input, to: output)
            try checkCancellation()
            var name = input.deletingPathExtension().lastPathComponent
            if lower.hasSuffix(".tar.gz") { name = String(input.lastPathComponent.dropLast(7)) }
            return try ArchiveFiles.commit(output, to: directory.appendingPathComponent(name))
        }
    }

    private func restoreAppleDouble(in root: URL) throws {
        let manager = FileManager.default
        func walk(_ directory: URL) throws -> Bool {
            var merged = false
            for child in try ArchiveFiles.children(directory) {
                try checkCancellation()
                let values = try child.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true {
                    let childMerged = try walk(child)
                    if childMerged && child.path.hasPrefix(root.appendingPathComponent("__MACOSX").path),
                       try ArchiveFiles.children(child).isEmpty { try manager.removeItem(at: child) }
                    merged = merged || childMerged
                    continue
                }
                guard try ArchiveFiles.isAppleDouble(child) else { continue }
                var relative = String(child.path.dropFirst(root.path.count + 1))
                if relative.hasPrefix("__MACOSX/") { relative = String(relative.dropFirst(9)) }
                let relativeURL = URL(fileURLWithPath: relative)
                let directoryPart = (relative as NSString).deletingLastPathComponent
                let counterpart = root.appendingPathComponent(directoryPart)
                    .appendingPathComponent(String(relativeURL.lastPathComponent.dropFirst(2)))
                guard manager.fileExists(atPath: counterpart.path) else { continue }
                guard copyfile(child.path, counterpart.path, nil, copyfile_flags_t(COPYFILE_UNPACK | COPYFILE_NOFOLLOW)) == 0 else {
                    throw ArchiveFailure("无法恢复 Mac 文件属性：\(counterpart.lastPathComponent)")
                }
                try manager.removeItem(at: child)
                merged = true
            }
            return merged
        }
        _ = try walk(root)
    }

    private func propagateQuarantine(from source: URL, to output: URL) throws {
        let key = "com.apple.quarantine"
        let size = getxattr(source.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        if size < 0 {
            if errno == ENOATTR { return }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard getxattr(source.path, key, &bytes, size, 0, XATTR_NOFOLLOW) == size else { throw CocoaError(.fileReadUnknown) }
        func apply(_ url: URL) throws {
            guard setxattr(url.path, key, bytes, bytes.count, 0, XATTR_NOFOLLOW) == 0 else { throw CocoaError(.fileWriteUnknown) }
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                for child in try ArchiveFiles.children(url) { try apply(child) }
            }
        }
        try apply(output)
    }
}
