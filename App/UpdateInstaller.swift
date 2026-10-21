import CryptoKit
import Darwin
import Foundation
import Security

/// 在应用同卷暂存并验证发布包，安装仅交换目录，旧版本始终保留。
enum UpdateInstaller {
    struct Prepared: Sendable {
        let workspace: URL
        let application: URL
        let destination: URL
    }

    static func prepare(release: UpdateChecker.Release, destination: URL) async throws -> Prepared {
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
            let name = "FastBudo-\(version)-macOS-arm64.zip"
            let base = URL(string: "https://github.com/lliony/fastbudo/releases/download/")!.appendingPathComponent(release.tag)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 300
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let manifestFile = try await download(base.appendingPathComponent("SHA256SUMS.txt"), session: session, maximumSize: 1024 * 1024)
            defer { try? manager.removeItem(at: manifestFile) }
            let manifest = try String(contentsOf: manifestFile, encoding: .utf8)
            let downloaded = try await download(base.appendingPathComponent(name), session: session, maximumSize: 512 * 1024 * 1024)
            defer { try? manager.removeItem(at: downloaded) }
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
            let extracted = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try engine.extract(archive, to: workspace)
            } onCancel: {
                engine.cancel()
            }
            let application = try application(in: extracted, version: version)
            try validateApplication(at: application, version: version)
            try Task.checkCancellation()
            try manager.removeItem(at: archive)
            return Prepared(workspace: workspace, application: application, destination: destination)
        } catch {
            try? manager.removeItem(at: workspace)
            throw error
        }
    }

    private static func download(_ url: URL, session: URLSession, maximumSize: Int) async throws -> URL {
        let (file, response) = try await session.download(from: url)
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
        guard bundle.executableArchitectures?.contains(NSNumber(value: NSBundleExecutableArchitectureARM64)) == true,
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
