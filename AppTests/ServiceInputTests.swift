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

@Suite @MainActor struct FinderRequestTests {
    @Test func menuRequestPreservesFilesAndFormat() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let files = [URL(fileURLWithPath: "/tmp/中文 & file.txt")]
        board.writeObjects(files.map { $0 as NSURL })
        for format in ["zip", "7z", "tar.gz"] {
            let url = try #require(FinderRequest.url(board: board.name.rawValue, format: format))
            let request = try FinderRequest.read(url)
            #expect(request.format == format)
            #expect(request.files == files)
        }
    }

    @Test func newItemRequestAcceptsOneDirectoryAndRejectsUnknownActions() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let root = URL(fileURLWithPath: "/tmp/test directory", isDirectory: true)
        board.writeObjects([root as NSURL])
        for type in ["folder", "txt", "md", "custom", "json"] {
            let url = try #require(FinderRequest.url(board: board.name.rawValue, format: type, action: "create"))
            let request = try FinderRequest.read(url)
            #expect(request.action == "create")
            #expect(request.files == [root])
            #expect(request.format == type)
        }
        #expect(FinderRequest.url(board: board.name.rawValue, format: "../bad", action: "create") == nil)
        #expect(FinderRequest.url(board: board.name.rawValue, format: "txt", action: "delete") == nil)
    }

    @Test func rejectsMalformedAndNonFileRequests() throws {
        #expect(throws: (any Error).self) { try FinderRequest.read(URL(string: "https://compress?format=7z&board=test")!) }
        #expect(FinderRequest.url(board: "test", format: "rar") == nil)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([NSURL(string: "https://example.com")!])
        let url = try #require(FinderRequest.url(board: board.name.rawValue, format: "zip"))
        #expect(throws: (any Error).self) { try FinderRequest.read(url) }
    }
}
