import CryptoKit
import Darwin
import Foundation
import Security

/// 在应用同卷暂存并验证发布包，安装仅交换目录，旧版本始终保留。
enum UpdateInstaller {
    enum Progress: Sendable, Equatable {
        case manifest, downloading(received: Int64, total: Int64), verifying, extracting, validating, installing

        var order: Int {
            switch self {
            case .manifest: 0
            case .downloading: 1
            case .verifying: 2
            case .extracting: 3
            case .validating: 4
            case .installing: 5
            }
        }
        var title: String {
            switch self {
            case .manifest: "正在获取更新信息…"
            case .downloading: "正在下载安装包…"
            case .verifying: "正在校验下载文件…"
            case .extracting: "正在解压新版本…"
            case .validating: "正在验证应用签名…"
            case .installing: "正在安装并重启…"
            }
        }
        var fraction: Double? {
            guard case let .downloading(received, total) = self, total > 0 else { return nil }
            return min(1, max(0, Double(received) / Double(total)))
        }
        var detail: String? {
            guard case let .downloading(received, total) = self else { return nil }
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            formatter.allowsNonnumericFormatting = false
            let downloaded = received <= 0 ? "0 B" : formatter.string(fromByteCount: received)
            guard total > 0, let fraction else { return "已下载 \(downloaded)" }
            return "\(downloaded) / \(formatter.string(fromByteCount: total)) · \(Int(fraction * 100))%"
        }
    }

    // completion-handler 下载不转发 download delegate 回调，直接观察任务实际字节计数。
    final class DownloadObserver: @unchecked Sendable {
        private let maximumSize: Int64
        private let progress: @Sendable (Progress) -> Void
        private let lock = NSLock()
        private var lastReport = -Double.infinity
        private var task: URLSessionDownloadTask?
        private var observation: NSKeyValueObservation?
        private var cancelled = false

        init(maximumSize: Int, progress: @escaping @Sendable (Progress) -> Void) {
            self.maximumSize = Int64(maximumSize)
            self.progress = progress
        }
        func start(_ task: URLSessionDownloadTask) {
            let observation = task.observe(\.countOfBytesReceived, options: [.initial, .new]) { [weak self] task, _ in
                self?.report(received: task.countOfBytesReceived, total: task.countOfBytesExpectedToReceive, task: task)
            }
            let cancelled = lock.withLock {
                self.task = task; self.observation = observation
                return self.cancelled
            }
            if cancelled { task.cancel() } else { task.resume() }
        }
        func cancel() {
            let task = lock.withLock { cancelled = true; return self.task }
            task?.cancel()
        }
        func finish() {
            let observation = lock.withLock {
                let value = self.observation
                self.observation = nil; task = nil
                return value
            }
            observation?.invalidate()
        }
        func report(received: Int64, total: Int64, task: URLSessionDownloadTask) {
            guard received <= maximumSize, total <= maximumSize else { task.cancel(); return }
            let shouldReport = lock.withLock {
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastReport >= 0.1 || received == total else { return false }
                lastReport = now
                return true
            }
            if shouldReport { progress(.downloading(received: received, total: total)) }
        }
    }

    struct Prepared: Sendable {
        let workspace: URL
        let application: URL
        let destination: URL
    }

    // 发布包按编译架构选择，避免 Intel 下载无法运行的 ARM 包。
    static func assetName(version: String) -> String {
        #if arch(x86_64)
        return "FastBudo-\(version)-macOS-x86_64.zip"
        #else
        return "FastBudo-\(version)-macOS-arm64.zip"
        #endif
    }

    static func prepare(release: UpdateChecker.Release, destination: URL,
                        progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> Prepared {
        let manager = FileManager.default
        let destination = destination.standardizedFileURL
        guard destination.pathExtension == "app",
              destination.resolvingSymlinksInPath() == destination else {
            throw ArchiveFailure("请从可写的本地应用目录运行 FastBudo 后更新。")
        }
        let workspace = destination.deletingLastPathComponent().appendingPathComponent(".fastbudo-update-\(UUID().uuidString)")
        try manager.createDirectory(at: workspace, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let version = release.tag.hasPrefix("v") ? String(release.tag.dropFirst()) : release.tag
            let name = assetName(version: version)
            let base = ReleaseSource.downloadBase(tag: release.tag)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            progress(.manifest)
            let manifestFile = try await download(base.appendingPathComponent("SHA256SUMS.txt"), session: session, maximumSize: 1024 * 1024)
            defer { try? manager.removeItem(at: manifestFile) }
            let manifest = try String(contentsOf: manifestFile, encoding: .utf8)
            progress(.downloading(received: 0, total: -1))
            let downloaded = try await download(base.appendingPathComponent(name), session: session,
                                                maximumSize: 512 * 1024 * 1024, progress: progress)
            defer { try? manager.removeItem(at: downloaded) }
            progress(.verifying)
            try verifyChecksum(file: downloaded, manifest: manifest, name: name)
            try Task.checkCancellation()
            let archive = workspace.appendingPathComponent(name)
            try manager.moveItem(at: downloaded, to: archive)
            let engine = ArchiveEngine()
            let timeout = Task {
                try await Task.sleep(for: .seconds(120))
                engine.cancel()
            }
            defer { timeout.cancel() }
            progress(.extracting)
            let extracted = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try engine.extract(archive, to: workspace)
            } onCancel: {
                engine.cancel()
            }
            let application = try application(in: extracted, version: version)
            progress(.validating)
            try validateApplication(at: application, version: version)
            try Task.checkCancellation()
            try manager.removeItem(at: archive)
            return Prepared(workspace: workspace, application: application, destination: destination)
        } catch {
            try? manager.removeItem(at: workspace)
            throw error
        }
    }

    private static func download(_ url: URL, session: URLSession, maximumSize: Int,
                                 progress: @escaping @Sendable (Progress) -> Void = { _ in }) async throws -> URL {
        let observer = DownloadObserver(maximumSize: maximumSize, progress: progress)
        let (file, response): (URL, URLResponse) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: url) { temporary, response, error in
                    observer.finish()
                    do {
                        if let error { throw error }
                        guard let temporary, let response else { throw URLError(.badServerResponse) }
                        let size = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size > 0, size <= maximumSize else { throw ArchiveFailure("安装包大小超出限制。") }
                        // 系统临时文件只在回调内有效，恢复 async 调用前先转移所有权。
                        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fastbudo-download-\(UUID().uuidString)")
                        try FileManager.default.moveItem(at: temporary, to: file)
                        progress(.downloading(received: Int64(size), total: Int64(size)))
                        continuation.resume(returning: (file, response))
                    } catch { continuation.resume(throwing: error) }
                }
                observer.start(task)
            }
        } onCancel: { observer.cancel() }
        do {
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.scheme == "https",
                  let host = response.url?.host,
                  ["github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host),
                  let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size > 0, size <= maximumSize else {
                throw ArchiveFailure("无法下载有效安装包或校验文件，请稍后重试。")
            }
            try Task.checkCancellation()
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    static func verifyChecksum(file: URL, manifest: String, name: String) throws {
        let matches = manifest.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2 else { return nil }
            let filename = fields[1].trimmingCharacters(in: .whitespaces)
            guard filename == name || filename == "*" + name else { return nil }
            return String(fields[0]).lowercased()
        }
        guard matches.count == 1, let expected = matches.first, expected.count == 64,
              expected.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ArchiveFailure("发布包缺少有效的 SHA-256 校验信息，未安装更新。")
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else {
            throw ArchiveFailure("安装包校验失败，原应用未修改。")
        }
    }

    static func application(in extracted: URL, version: String) throws -> URL {
        let candidates = [extracted.appendingPathComponent("FastBudo.app"),
                          extracted.appendingPathComponent("FastBudo-\(version)/FastBudo.app")]
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        guard candidates.count == 1, let application = candidates.first else {
            throw ArchiveFailure("安装包中未找到唯一的 FastBudo 应用。")
        }
        return application
    }

    static func validateApplication(at url: URL, version: String) throws {
        guard let bundle = Bundle(url: url), bundle.bundleIdentifier == "local.fastbudo.app",
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version,
              let executable = bundle.executableURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ArchiveFailure("安装包的应用标识、版本或可执行文件无效。")
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let systemVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(x86_64)
        let architecture = NSBundleExecutableArchitectureX86_64
        #else
        let architecture = NSBundleExecutableArchitectureARM64
        #endif
        guard bundle.executableArchitectures?.contains(NSNumber(value: architecture)) == true,
              (bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String ?? "0")
                .compare(systemVersion, options: .numeric) != .orderedDescending else {
            throw ArchiveFailure("新版本不支持当前处理器或 macOS 版本。")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil) == errSecSuccess else {
            throw ArchiveFailure("安装包签名完整性检查失败，原应用未修改。")
        }
    }

    static func swap(_ installed: URL, _ staged: URL) throws {
        guard renameatx_np(AT_FDCWD, installed.path, AT_FDCWD, staged.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    // 只等待旧进程退出并重新打开；路径通过参数传入，不拼接进 shell 源码。
    // shortcut: 仅自动恢复启动请求失败；启动后崩溃需从保留的旧版本恢复，需自动恢复时加入启动握手。
    static let relaunchScript = #"""
    count=0
    while kill -0 "$1" 2>/dev/null; do
        count=$((count + 1))
        [ "$count" -lt 30 ] || exit 1
        sleep 1
    done
    if ! "$4" -n "$2"; then
        /bin/mv "$2" "$3/failed.app" && /bin/mv "$5" "$2" && "$4" -n "$2"
    fi
    """#
}
