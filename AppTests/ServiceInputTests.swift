import AppKit
import Testing
@testable import FastBudo

@Suite @MainActor struct ServiceInputTests {
    @Test func preservesFileOrder() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let first = URL(fileURLWithPath: "/tmp/中文 file.txt")
        let second = URL(fileURLWithPath: "/tmp/second.txt")
        board.writeObjects([first as NSURL, second as NSURL])
        #expect(try ServiceInput.urls(from: board) == [first, second])
    }

    @Test func rejectsEmptyAndNonFileRequests() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        #expect(throws: ServiceInput.InputError.self) { try ServiceInput.urls(from: board) }
        board.writeObjects([NSURL(string: "https://example.com/archive.zip")!])
        #expect(throws: ServiceInput.InputError.self) { try ServiceInput.urls(from: board) }
    }
}
