import AppKit
import Testing
@testable import FastBudo

@Suite(.serialized)
@MainActor struct LaunchTests {
    @Test func clipboardPanelDoesNotActivateMainWindows() throws {
        let board = NSPasteboard.withUniqueName()
        let suite = "FastBudoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let clipboard = ClipboardController(defaults: defaults, board: board)
        let delegate = AppDelegate(clipboard: clipboard)
        defer {
            clipboard.hide(); clipboard.stop(); board.releaseGlobally()
            defaults.removePersistentDomain(forName: suite)
        }
        clipboard.show()
        let panel = try #require(NSApp.windows.first { $0.title == "FastBudo 剪贴板" && $0.isVisible } as? NSPanel)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(delegate.settingsWindow == nil)
        clipboard.hide()
        clipboard.toggle()
        #expect(panel.isVisible)
        #expect(delegate.settingsWindow == nil)
    }

    @Test func updateAllowsDeferredTerminationBeforeRollingBack() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let installed = root.appendingPathComponent("installed.app")
        let workspace = root.appendingPathComponent("update")
        let staged = workspace.appendingPathComponent("staged.app")
        for (url, value) in [(installed, "old"), (staged, "new")] {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
            try Data(value.utf8).write(to: url.appendingPathComponent("version"))
        }
        let board = NSPasteboard.withUniqueName()
        let suite = "FastBudoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let clipboard = ClipboardController(defaults: defaults, board: board)
        var requested = false
        let delegate = AppDelegate(clipboard: clipboard, requestTermination: { requested = true })
        defer {
            clipboard.stop(); board.releaseGlobally(); defaults.removePersistentDomain(forName: suite)
            try? manager.removeItem(at: root)
        }
        let task = Task { try await delegate.installUpdate(.init(workspace: workspace, application: staged, destination: installed)) }
        for _ in 0..<100 where !requested { try await Task.sleep(for: .milliseconds(10)) }
        #expect(requested)
        #expect(try String(contentsOf: installed.appendingPathComponent("version"), encoding: .utf8) == "new")
        // 退出请求返回后仍应留出 AppKit 退出时间；取消界面任务不能跳过这段保护。
        task.cancel()
        try await Task.sleep(for: .milliseconds(50))
        #expect(try String(contentsOf: installed.appendingPathComponent("version"), encoding: .utf8) == "new")
        switch await task.result {
        case .success: Issue.record("未退出时应超时回滚")
        case .failure: break
        }
        #expect(try String(contentsOf: installed.appendingPathComponent("version"), encoding: .utf8) == "old")
        #expect(!manager.fileExists(atPath: workspace.path))
    }

    @Test func settingsFollowLaunchIntentAndReopen() throws {
        let originalPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(originalPolicy) }
        let board = NSPasteboard.withUniqueName()
        let suite = "FastBudoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "clipHotKeyEnabled")
        let clipboard = ClipboardController(defaults: defaults, board: board)
        let delegate = AppDelegate(clipboard: clipboard)
        defer { clipboard.stop(); board.releaseGlobally(); defaults.removePersistentDomain(forName: suite) }
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification,
            userInfo: [NSApplication.launchIsDefaultUserInfoKey: false]))
        #expect(delegate.settingsWindow == nil)
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification,
            userInfo: [NSApplication.launchIsDefaultUserInfoKey: true]))
        let window = try #require(delegate.settingsWindow)
        defer { window.close() }
        #expect(window.isVisible)
        #expect(NSApp.activationPolicy() == .regular)
        window.close()
        #expect(!window.isVisible)
        #expect(NSApp.activationPolicy() == .accessory)
        #expect(delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp) == false)
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        #expect(NSApp.activationPolicy() == .regular)
        #expect(delegate.settingsWindow === window)
        #expect(window.isVisible)
    }
}
