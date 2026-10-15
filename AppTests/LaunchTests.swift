import AppKit
import Testing
@testable import FastBudo

@MainActor struct LaunchTests {
    @Test func settingsFollowLaunchIntentAndReopen() throws {
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
        window.close()
        #expect(!window.isVisible)
        #expect(!delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false))
        #expect(delegate.settingsWindow === window)
        #expect(window.isVisible)
    }
}
