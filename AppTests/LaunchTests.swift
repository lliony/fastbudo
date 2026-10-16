import AppKit
import Testing
@testable import FastBudo

@MainActor struct LaunchTests {
    @Test func settingsFollowLaunchIntentAndReopen() throws {
        let originalPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(originalPolicy) }
        let board = NSPasteboard.withUniqueName()
        let suite = "FastBudoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "clipHotKeyEnabled")
        let clipboard = ClipboardController(defaults: defaults, board: board)
        let delegate = AppDelegate(clipboard: clipboard, menuBar: MenuBarController(defaults: defaults, statusBar: nil))
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
