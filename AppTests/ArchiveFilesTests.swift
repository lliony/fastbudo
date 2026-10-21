import Darwin
import Foundation
import Testing
@testable import FastBudo

struct ArchiveFilesTests {
    @Test func selectedRootsKeepOrderAndPathBoundaries() {
        func url(_ path: String) -> URL { URL(fileURLWithPath: path) }
        #expect(ArchiveFiles.selectedRoots([url("/tmp/ab"), url("/tmp/a"), url("/tmp/a/x"), url("/tmp/a")]).map(\.path) == ["/tmp/ab", "/tmp/a"])
        #expect(ArchiveFiles.selectedRoots([url("/tmp/a"), url("/")]).map(\.path) == ["/"])
        #expect(ArchiveFiles.selectedRoots([url("/tmp/中文"), url("/tmp/中文/字"), url("/tmp/A"), url("/tmp/a")]).map(\.path) == ["/tmp/中文", "/tmp/A", "/tmp/a"])
    }

    @Test func stagingFiltersOnlyKnownMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let stage = root.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        for name in [".DS_Store", ".gitignore", "._notes", "中文.txt"] {
            try Data(name.utf8).write(to: source.appendingPathComponent(name))
        }
        try ArchiveFiles.stage([source], into: stage, excludeDSStore: true, preserveAttributes: false)
        for name in [".gitignore", "._notes", "中文.txt"] {
            #expect(try Data(contentsOf: stage.appendingPathComponent("source").appendingPathComponent(name)) == Data(name.utf8))
        }
        #expect(!FileManager.default.fileExists(atPath: stage.appendingPathComponent("source/.DS_Store").path))
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent(".DS_Store").path))
    }

    @Test func stagingRejectsSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: (any Error).self) {
            try ArchiveFiles.stage([link], into: root.appendingPathComponent("stage"), excludeDSStore: true, preserveAttributes: false)
        }
    }

    @Test func committingNeverOverwrites() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let existing = root.appendingPathComponent("archive.zip")
        let staged = root.appendingPathComponent("temporary")
        try Data("original".utf8).write(to: existing)
        try Data("new".utf8).write(to: staged)
        let output = try ArchiveFiles.commit(staged, to: existing)
        #expect(output.lastPathComponent == "archive 2.zip")
        #expect(try Data(contentsOf: existing) == Data("original".utf8))
        #expect(try Data(contentsOf: output) == Data("new".utf8))
    }
    @Test func filtersRecognizedSequesteredAppleDouble() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let metadata = source.appendingPathComponent("__MACOSX")
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("file.txt")
        try Data("body".utf8).write(to: file)
        let attribute = Data("metadata".utf8)
        #expect(attribute.withUnsafeBytes { setxattr(file.path, "com.fastbudo.test", $0.baseAddress, attribute.count, 0, 0) } == 0)
        let sidecar = metadata.appendingPathComponent("._file.txt")
        #expect(copyfile(file.path, sidecar.path, nil, copyfile_flags_t(COPYFILE_PACK | COPYFILE_XATTR)) == 0)
        let stage = root.appendingPathComponent("stage")
        try ArchiveFiles.stage([source], into: stage, excludeDSStore: true, preserveAttributes: false)
        #expect(!FileManager.default.fileExists(atPath: stage.appendingPathComponent("source/__MACOSX/._file.txt").path))
        #expect(try Data(contentsOf: stage.appendingPathComponent("source/file.txt")) == Data("body".utf8))
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
    }

}
