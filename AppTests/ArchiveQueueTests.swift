import Foundation
import Testing
@testable import FastBudo

@MainActor struct ArchiveQueueTests {
    @Test func queueKeepsSubmissionOrderAndUniqueOutputs() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let input = root.appendingPathComponent("file")
        try Data("data".utf8).write(to: input)
        let model = ArchiveModel()
        let request = CreateRequest(inputs: [input], outputDirectory: root, name: "archive")
        model.enqueue(ArchiveJob(operation: .create(request)))
        model.enqueue(ArchiveJob(operation: .create(request)))
        #expect(model.pending.count == 1)
        let deadline = Date().addingTimeInterval(15)
        while model.busy && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(!model.busy)
        #expect(model.failed == nil)
        #expect(model.results.map(\.lastPathComponent) == ["archive 2.zip", "archive.zip"])
    }
}
