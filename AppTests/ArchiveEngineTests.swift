import Darwin
import Foundation
import Testing
@testable import FastBudo

struct ArchiveEngineTests {
    @Test(arguments: ArchiveFormat.allCases) func archiveRoundTrip(_ format: ArchiveFormat) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("中文 file.txt")
        let payload = Data("archive content".utf8)
        try payload.write(to: file)
        let engine = ArchiveEngine()
        let archive = try engine.create(CreateRequest(inputs: [file], outputDirectory: root, name: "result", format: format))
        let output = try engine.extract(archive, to: root)
        #expect(try Data(contentsOf: output.appendingPathComponent(file.lastPathComponent)) == payload)
    }

    @Test func encryptedSevenZipAndWrongPassword() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("input.txt")
        try Data("secret content".utf8).write(to: file)
        let engine = ArchiveEngine()
        let archive = try engine.create(CreateRequest(inputs: [file], outputDirectory: root, name: "encrypted", format: .sevenZip), password: "test-only")
        #expect(throws: (any Error).self) { try engine.extract(archive, to: root, password: "wrong") }
        let output = try engine.extract(archive, to: root, password: "test-only")
        #expect(try Data(contentsOf: output.appendingPathComponent("input.txt")) == Data("secret content".utf8))
    }
    @Test func macAttributesRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("input.txt")
        try Data("file data".utf8).write(to: file)
        let tags = try PropertyListSerialization.data(fromPropertyList: ["FastBudo\n6"], format: .binary, options: 0)
        let attributes = ["com.fastbudo.test": Data("attribute".utf8), "com.apple.ResourceFork": Data("resource".utf8), "com.apple.metadata:_kMDItemUserTags": tags]
        for (name, value) in attributes {
            let result = value.withUnsafeBytes { setxattr(file.path, name, $0.baseAddress, value.count, 0, 0) }
            #expect(result == 0)
        }
        let engine = ArchiveEngine()
        let archive = try engine.create(CreateRequest(inputs: [file], outputDirectory: root, name: "attributes", preserveAttributes: true))
        let output = try engine.extract(archive, to: root).appendingPathComponent("input.txt")
        for (name, value) in attributes {
            var bytes = [UInt8](repeating: 0, count: value.count)
            #expect(getxattr(output.path, name, &bytes, bytes.count, 0, 0) == value.count)
            #expect(Data(bytes) == value)
        }
        let clean = try engine.create(CreateRequest(inputs: [file], outputDirectory: root, name: "clean"))
        let cleanFile = try engine.extract(clean, to: root).appendingPathComponent("input.txt")
        #expect(getxattr(cleanFile.path, "com.fastbudo.test", nil, 0, 0, 0) == -1)
        #expect(try Data(contentsOf: file) == Data("file data".utf8))
    }

    @Test func cancellationCleansWorkspaceAndKeepsSource() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("large.bin")
        let bytes = Data(repeating: 0x7B, count: 32 * 1024 * 1024)
        try bytes.write(to: file)
        let engine = ArchiveEngine()
        let task = Task.detached { try engine.create(CreateRequest(inputs: [file], outputDirectory: root, name: "cancelled", format: .sevenZip)) }
        try await Task.sleep(for: .milliseconds(5))
        engine.cancel()
        do {
            _ = try await task.value
            Issue.record("取消的任务不应提交成品")
        } catch is CancellationError { }
        #expect(try Data(contentsOf: file) == bytes)
        #expect(try ArchiveFiles.children(root).map(\.lastPathComponent) == ["large.bin"])
    }

    @Test func zipAESRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("data.txt")
        try Data("zip content".utf8).write(to: file)
        let engine = ArchiveEngine()
        let archive = try engine.create(CreateRequest(inputs: [file], outputDirectory: root, name: "aes"), password: "test-password")
        let output = try engine.extract(archive, to: root, password: "test-password")
        #expect(try Data(contentsOf: output.appendingPathComponent("data.txt")) == Data("zip content".utf8))
    }

    @Test func readOnlyOutputDoesNotChangeSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let readonly = root.appendingPathComponent("readonly")
        defer {
            _ = chmod(readonly.path, 0o700)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: readonly, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("source.txt")
        try Data("unchanged".utf8).write(to: input)
        #expect(chmod(readonly.path, 0o500) == 0)
        #expect(throws: (any Error).self) {
            try ArchiveEngine().create(CreateRequest(inputs: [input], outputDirectory: readonly, name: "archive"))
        }
        #expect(try Data(contentsOf: input) == Data("unchanged".utf8))
    }

}
