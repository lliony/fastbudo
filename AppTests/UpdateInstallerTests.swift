import Foundation
import Testing
import os
@testable import FastBudo

struct UpdateInstallerTests {
    @Test func downloadProgressHandlesKnownAndUnknownSizes() {
        let events = OSAllocatedUnfairLock(initialState: [UpdateInstaller.Progress]())
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(with: URL(string: "https://example.invalid/update.zip")!)
        let observer = UpdateInstaller.DownloadObserver(maximumSize: 100) { value in
            events.withLock { $0.append(value) }
        }
        observer.report(received: 25, total: 100, task: task)
        #expect(events.withLock { $0.last?.fraction } == 0.25)
        observer.report(received: 100, total: 100, task: task)
        #expect(events.withLock { $0.last?.fraction } == 1)
        let unknown = UpdateInstaller.Progress.downloading(received: 25, total: -1)
        #expect(UpdateInstaller.Progress.downloading(received: 0, total: -1).detail == "已下载 0 B")
        #expect(UpdateInstaller.Progress.downloading(received: 0, total: 100).detail?.contains("0%") == true)
        #expect(unknown.fraction == nil)
        #expect(unknown.detail?.contains("已下载") == true)
        #expect(UpdateInstaller.Progress.verifying.fraction == nil)
        #expect(UpdateInstaller.Progress.downloading(received: 110, total: 100).fraction == 1)
        #expect(UpdateInstaller.Progress.downloading(received: -1, total: 100).fraction == 0)
    }

    @Test func oversizedDownloadCancelsBeforeCompletion() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for (received, expected): (Int64, Int64) in [(1, 101), (101, -1)] {
            let task = session.downloadTask(with: URL(string: "https://example.invalid/update.zip")!)
            let observer = UpdateInstaller.DownloadObserver(maximumSize: 100) { _ in Issue.record("超限下载不应上报有效进度") }
            observer.report(received: received, total: expected, task: task)
            #expect(task.state == .canceling || task.state == .completed)
        }
    }

    @Test func assetMatchesBuildArchitecture() {
        #if arch(x86_64)
        #expect(UpdateInstaller.assetName(version: "0.0.2") == "FastBudo-0.0.2-macOS-x86_64.zip")
        #else
        #expect(UpdateInstaller.assetName(version: "0.0.2") == "FastBudo-0.0.2-macOS-arm64.zip")
        #endif
    }

    @Test func checksumRequiresExactAssetAndMatchingBytes() throws {
        let name = "FastBudo-0.0.2-macOS-arm64.zip"
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let zip = root.appendingPathComponent(name)
        try Data("abc".utf8).write(to: zip)
        try UpdateInstaller.verifyChecksum(file: zip, manifest: "\(digest)  \(name)", name: name)
        for manifest in ["\(digest)  other.zip", "bad  \(name)", "\(digest)  \(name)\n\(digest)  \(name)"] {
            #expect(throws: (any Error).self) {
                try UpdateInstaller.verifyChecksum(file: zip, manifest: manifest, name: name)
            }
        }
        try Data("changed".utf8).write(to: zip)
        #expect(throws: (any Error).self) {
            try UpdateInstaller.verifyChecksum(file: zip, manifest: "\(digest)  \(name)", name: name)
        }
    }

    @Test func swapPreservesOldApplicationAndCanRollBack() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let installed = root.appendingPathComponent("installed.app")
        let staged = root.appendingPathComponent("staged.app")
        for (url, value) in [(installed, "old"), (staged, "new")] {
            try manager.createDirectory(at: url, withIntermediateDirectories: false)
            try Data(value.utf8).write(to: url.appendingPathComponent("version"))
        }
        try UpdateInstaller.swap(installed, staged)
        #expect(try String(contentsOf: installed.appendingPathComponent("version"), encoding: .utf8) == "new")
        #expect(try String(contentsOf: staged.appendingPathComponent("version"), encoding: .utf8) == "old")
        try UpdateInstaller.swap(installed, staged)
        #expect(try String(contentsOf: installed.appendingPathComponent("version"), encoding: .utf8) == "old")
        #expect(throws: (any Error).self) {
            try UpdateInstaller.swap(installed, root.appendingPathComponent("missing.app"))
        }
        #expect(try String(contentsOf: installed.appendingPathComponent("version"), encoding: .utf8) == "old")
    }

    @Test func relaunchFailureRestoresOldApplication() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("更新测试 \(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        let installed = root.appendingPathComponent("FastBudo.app")
        let backup = root.appendingPathComponent("backup.app")
        for (url, value) in [(installed, "new"), (backup, "old")] {
            try manager.createDirectory(at: url, withIntermediateDirectories: false)
            try Data(value.utf8).write(to: url.appendingPathComponent("version"))
        }
        let launcher = root.appendingPathComponent("open-stub")
        try Data("#!/bin/sh\n[ \"$(cat \"$2/version\")\" = old ]\n".utf8).write(to: launcher)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", UpdateInstaller.relaunchScript, "test", "999999999",
                             installed.path, root.path, launcher.path, backup.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: installed.appendingPathComponent("version"), encoding: .utf8) == "old")
        #expect(try String(contentsOf: root.appendingPathComponent("failed.app/version"), encoding: .utf8) == "new")
    }

    @Test func signedBundleRequiresMatchingVersionAndUntamperedContents() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let application = root.appendingPathComponent("FastBudo.app")
        let contents = application.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/FastBudo")
        try manager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        try manager.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        let plist = contents.appendingPathComponent("Info.plist")
        var metadata = ["CFBundleIdentifier": "local.fastbudo.app", "CFBundleExecutable": "FastBudo",
                        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.0.2",
                        "CFBundleVersion": "1", "LSMinimumSystemVersion": "27.0"]
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: plist)
        let signing = Process()
        signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signing.arguments = ["--force", "--sign", "-", application.path]
        try signing.run()
        signing.waitUntilExit()
        #expect(signing.terminationStatus == 0)
        try UpdateInstaller.validateApplication(at: application, version: "0.0.2")
        #expect(throws: (any Error).self) {
            try UpdateInstaller.validateApplication(at: application, version: "0.0.3")
        }
        metadata["CFBundleVersion"] = "tampered"
        try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0).write(to: plist)
        #expect(throws: (any Error).self) {
            try UpdateInstaller.validateApplication(at: application, version: "0.0.2")
        }
    }

    @Test func locatesVersionedReleaseFolderAndRejectsAmbiguity() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let packaged = root.appendingPathComponent("FastBudo-0.0.2/FastBudo.app")
        try manager.createDirectory(at: packaged, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        #expect(try UpdateInstaller.application(in: root, version: "0.0.2").path == packaged.path)
        let direct = root.appendingPathComponent("FastBudo.app")
        try manager.createDirectory(at: direct, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try UpdateInstaller.application(in: root, version: "0.0.2") }
        try manager.removeItem(at: packaged)
        #expect(try UpdateInstaller.application(in: root, version: "0.0.2").path == direct.path)
    }

    @Test func invalidBundleCannotBeInstalled() {
        #expect(throws: (any Error).self) {
            try UpdateInstaller.validateApplication(at: URL(fileURLWithPath: "/tmp/nonexistent-fastbudo.app"), version: "0.0.2")
        }
    }
}
