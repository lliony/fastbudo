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
