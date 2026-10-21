import Darwin
import Foundation

enum ArchiveFiles {
    // 只把确认属于 AppleDouble 且有对应文件的条目视作元数据。
    static func isAppleDouble(_ url: URL) throws -> Bool {
        guard url.lastPathComponent.hasPrefix("._") else { return false }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let header = try input.read(upToCount: 26) ?? Data()
        guard header.count == 26 else { return false }
        func number(_ bytes: Data) -> UInt64 { bytes.reduce(0) { ($0 << 8) | UInt64($1) } }
        guard number(header.prefix(4)) == 0x00051607,
              number(header.dropFirst(4).prefix(4)) == 0x00020000 else { return false }
        let count = Int(number(header.suffix(2)))
        guard count > 0, count <= 1024 else { return false }
        let entries = try input.read(upToCount: count * 12) ?? Data()
        guard entries.count == count * 12 else { return false }
        let length = try input.seekToEnd()
        for index in 0..<count {
            let offset = number(entries[(index * 12 + 4)..<(index * 12 + 8)])
            let size = number(entries[(index * 12 + 8)..<(index * 12 + 12)])
            guard offset >= 26 + count * 12, offset <= length, size <= length - offset else { return false }
        }
        return true
    }

    /// 保留首次选择顺序，只沿祖先链排除已经包含在所选目录中的路径。
    static func selectedRoots(_ inputs: [URL]) -> [URL] {
        var paths = Set<String>()
        let unique = inputs.map(\.standardizedFileURL).filter { paths.insert($0.path).inserted }
        return unique.filter { input in
            var path = input.path
            while path != "/" {
                let parent = (path as NSString).deletingLastPathComponent
                if parent == path || parent.isEmpty { break }
                if paths.contains(parent) { return false }
                path = parent
            }
            return true
        }
    }

    static func stage(_ inputs: [URL], into destination: URL, excludeDSStore: Bool,
                      preserveAttributes: Bool, checkCancellation: () throws -> Void = {}) throws {
        let manager = FileManager.default
        let unique = selectedRoots(inputs)
        guard !unique.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        guard Set(unique.map { $0.lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() }).count == unique.count else {
            throw CocoaError(.fileWriteFileExists)
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        for input in unique {
            _ = try copy(input, sourceRoot: input, to: destination.appendingPathComponent(input.lastPathComponent),
                     excludedTree: destination.deletingLastPathComponent(), excludeDSStore: excludeDSStore,
                     preserveAttributes: preserveAttributes, checkCancellation: checkCancellation)
        }
    }

    private static func copy(_ source: URL, sourceRoot: URL, to target: URL, excludedTree: URL, excludeDSStore: Bool,
                             preserveAttributes: Bool, checkCancellation: () throws -> Void) throws -> Bool {
        try checkCancellation()
        guard source.standardizedFileURL != excludedTree.standardizedFileURL else { return false }
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: source.path)
        guard let type = attributes[.type] as? FileAttributeType,
              type == .typeRegular || type == .typeDirectory else { throw CocoaError(.featureUnsupported) }
        if excludeDSStore && source.lastPathComponent == ".DS_Store" { return false }
        if !preserveAttributes && type == .typeRegular && source.lastPathComponent.hasPrefix("._") {
            var companion = source.deletingLastPathComponent().appendingPathComponent(String(source.lastPathComponent.dropFirst(2)))
            let relative = String(source.path.dropFirst(sourceRoot.path.count + 1))
            if relative.hasPrefix("__MACOSX/") {
                let unwrapped = String(relative.dropFirst(9))
                companion = sourceRoot.appendingPathComponent((unwrapped as NSString).deletingLastPathComponent)
                    .appendingPathComponent(String(source.lastPathComponent.dropFirst(2)))
            }
            if manager.fileExists(atPath: companion.path), try isAppleDouble(source) { return false }
        }
        if type == .typeDirectory {
            try manager.createDirectory(at: target, withIntermediateDirectories: false)
            let entries = try children(source)
            var copied = false
            for child in entries {
                let included = try copy(child, sourceRoot: sourceRoot, to: target.appendingPathComponent(child.lastPathComponent), excludedTree: excludedTree,
                         excludeDSStore: excludeDSStore, preserveAttributes: preserveAttributes,
                         checkCancellation: checkCancellation)
                copied = copied || included
            }
            let relative = String(source.path.dropFirst(sourceRoot.path.count + 1))
            if !preserveAttributes && (relative == "__MACOSX" || relative.hasPrefix("__MACOSX/")) && !entries.isEmpty && !copied {
                try manager.removeItem(at: target)
                return false
            }
            if preserveAttributes {
                guard copyfile(source.path, target.path, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_NOFOLLOW)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        } else {
            let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
            defer { close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw CocoaError(.featureUnsupported) }
            let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600)
            guard output >= 0 else { throw CocoaError(.fileWriteUnknown) }
            defer { close(output) }
            let reader = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let writer = FileHandle(fileDescriptor: output, closeOnDealloc: false)
            while let data = try reader.read(upToCount: 1024 * 1024), !data.isEmpty {
                try checkCancellation()
                try writer.write(contentsOf: data)
            }
            if preserveAttributes {
                guard fcopyfile(fd, output, nil, copyfile_flags_t(COPYFILE_XATTR)) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            var after = stat()
            guard fstat(fd, &after) == 0, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                  before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw CocoaError(.fileReadUnknown) }
        }
        var kept: [FileAttributeKey: Any] = [:]
        kept[.modificationDate] = attributes[.modificationDate]
        if let mode = attributes[.posixPermissions] as? NSNumber { kept[.posixPermissions] = mode.intValue & 0o777 }
        try manager.setAttributes(kept, ofItemAtPath: target.path)
        return true
    }

    // Foundation 会隐藏所有 ._ 条目，包括用户的普通文件；这里必须按真实目录项枚举。
    static func children(_ directory: URL) throws -> [URL] {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        guard let stream = fdopendir(descriptor) else { close(descriptor); throw CocoaError(.fileReadUnknown) }
        defer { closedir(stream) }
        var result: [URL] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." { result.append(directory.appendingPathComponent(name)) }
        }
        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func commit(_ staged: URL, to target: URL) throws -> URL {
        var index = 1
        while true {
            let candidate: URL
            if index == 1 { candidate = target }
            else {
                let ext = target.pathExtension
                let base = target.deletingPathExtension().lastPathComponent
                candidate = target.deletingLastPathComponent().appendingPathComponent("\(base) \(index)" + (ext.isEmpty ? "" : ".\(ext)"))
            }
            if renamex_np(staged.path, candidate.path, UInt32(RENAME_EXCL)) == 0 { return candidate }
            guard errno == EEXIST else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            index += 1
        }
    }
}
