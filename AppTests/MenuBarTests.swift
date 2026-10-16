import AppKit
import Testing
@testable import FastBudo

@MainActor struct MenuBarTests {
    @Test func lifecycleAndPreferences() {
        let name = "FastBudoTests.MenuBar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let controller = MenuBarController(defaults: defaults, statusBar: nil)
        defer { controller.stop() }
        #expect(!controller.enabled)
        #expect(!controller.collapseOnLaunch)
        controller.start()
        controller.toggle()
        #expect(!controller.isCollapsed)
        controller.collapseOnLaunch = true
        controller.enabled = true
        #expect(!controller.isCollapsed)
        controller.toggle()
        #expect(controller.isCollapsed)
        controller.start()
        #expect(controller.isCollapsed)
        controller.expand()
        #expect(!controller.isCollapsed)
        controller.toggle()
        controller.enabled = false
        #expect(!controller.isCollapsed)
        controller.enabled = true
        #expect(!controller.isCollapsed)
        controller.stop()
        controller.stop()
        controller.toggle()
        #expect(!controller.isCollapsed)
        #expect(defaults.bool(forKey: "menuBarEnabled"))
        let restored = MenuBarController(defaults: defaults, statusBar: nil)
        defer { restored.stop() }
        #expect(restored.enabled)
        #expect(restored.collapseOnLaunch)
        restored.start()
        #expect(restored.isCollapsed)
        restored.collapseOnLaunch = false
        #expect(restored.isCollapsed)
        restored.stop()
        restored.start()
        #expect(!restored.isCollapsed)
    }
}
