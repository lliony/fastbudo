import AppKit
import Testing
@testable import FastBudo

struct NewItemTests {
    @Test func createsFilesAndFoldersWithoutOverwriting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try NewItem.create(in: root, name: "未命名.txt", folder: false)
        try Data("keep".utf8).write(to: original)
        let second = try NewItem.create(in: root, name: "未命名.txt", folder: false)
        #expect(second.lastPathComponent == "未命名 2.txt")
        #expect(try String(contentsOf: original, encoding: .utf8) == "keep")
        let folder = try NewItem.create(in: root, name: "新建文件夹", folder: true)
        #expect(try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true)
        #expect(try NewItem.create(in: root, name: "新建文件夹", folder: true).lastPathComponent == "新建文件夹 2")
        for name in ["", ".", "..", "../escape", "a/b", "a:b", "a\u{0}b"] {
            #expect(throws: (any Error).self) { try NewItem.create(in: root, name: name, folder: false) }
        }
    }
    @Test func doesNotFollowExistingLinkOrCreateMissingParent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("original")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file.txt"), withDestinationURL: target)
        #expect(try NewItem.create(in: root, name: "file.txt", folder: false).lastPathComponent == "file 2.txt")
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect(throws: (any Error).self) {
            try NewItem.create(in: root.appendingPathComponent("missing"), name: "a", folder: false)
        }
    }

    @Test func validatesCommonTypes() {
        #expect(NewItemTypes.parse("txt, md, json, txt") == ["txt", "md", "json"])
        #expect(NewItemTypes.parse("../bad, a/b, , .txt") == ["txt"])
    }
}

struct FinderNewItemDestinationTests {
    @Test func selectedItemsCreateBesideSelection() {
        let root = URL(fileURLWithPath: "/tmp/menu-test", isDirectory: true)
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        let file = root.appendingPathComponent("file.txt")
        #expect(FinderRequest.creationDirectory(for: [folder]) == root)
        #expect(FinderRequest.creationDirectory(for: [folder, file]) == root)
        #expect(FinderRequest.creationDirectory(for: []) == nil)
        #expect(FinderRequest.creationDirectory(for: [file, URL(fileURLWithPath: "/other/file")]) == nil)
        #expect(FinderRequest.creationDirectory(for: [URL(string: "https://example.com/file")!]) == nil)
    }
}


@MainActor struct NewItemFinderTests {
    @Test func createsBeforeFinderRenameWithoutPrompt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "FastBudoTests.NewItem.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let board = NSPasteboard.withUniqueName()
        let clipboard = ClipboardController(defaults: defaults, board: board)
        var revealed: [URL] = []
        let delegate = AppDelegate(clipboard: clipboard, revealNewItem: { revealed.append($0) })
        defer { clipboard.stop(); board.releaseGlobally(); defaults.removePersistentDomain(forName: suite) }
        for (type, expected) in [("txt", "未命名.txt"), ("md", "未命名.md"), ("folder", "新建文件夹"), ("custom", "未命名 2.txt")] {
            var prompted = false
            let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
                MainActor.assumeIsolated {
                    prompted = true
                    NSApp.abortModal()
                }
            }
            RunLoop.main.add(timer, forMode: .modalPanel)
            delegate.createItem(in: root, type: type)
            timer.invalidate()
            #expect(!prompted)
            #expect(revealed.last?.lastPathComponent == expected)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(expected).path))
        }
    }
}


@MainActor struct FinderRenameTests {
    @Test func onlyRenamesTheExactSingleSelection() {
        let target = URL(fileURLWithPath: "/tmp/new-item/未命名.txt")
        #expect(FinderRename.matches([target], target: target))
        #expect(!FinderRename.matches([], target: target))
        #expect(!FinderRename.matches([URL(fileURLWithPath: "/tmp/other/未命名.txt")], target: target))
        #expect(!FinderRename.matches([target, URL(fileURLWithPath: "/tmp/new-item/other.txt")], target: target))
    }
}
