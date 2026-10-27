import AppKit
import Carbon
import Testing
@testable import FastBudo

struct ShortcutRecorderTests {
    @Test func validCombinations() {
        #expect(ClipboardHotKey.accepts(key: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey)))
        #expect(ClipboardHotKey.accepts(key: UInt32(kVK_F1), modifiers: 0))
        for key in [kVK_ANSI_K, kVK_ANSI_1, kVK_Space, kVK_Escape, kVK_LeftArrow] {
            for modifiers in [0, shiftKey, optionKey, shiftKey | optionKey] {
                #expect(ClipboardHotKey.accepts(key: UInt32(key), modifiers: UInt32(modifiers)))
            }
        }
        #expect(!ClipboardHotKey.accepts(key: 128, modifiers: 0))
        #expect(!ClipboardHotKey.accepts(key: 1, modifiers: UInt32.max))
        #expect(!ClipboardHotKey.accepts(key: UInt32(kVK_Command), modifiers: UInt32(cmdKey)))
        #expect(ClipboardHotKey.accepts(key: UInt32(kVK_Escape), modifiers: UInt32(cmdKey)))
    }

    @Test @MainActor func eventFlagsAndLabel() throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 0, windowNumber: 0, context: nil, characters: "K", charactersIgnoringModifiers: "k",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_K)))
        let shortcut = try #require(RecordedShortcut(event: event))
        #expect(shortcut.modifiers == UInt32(cmdKey | shiftKey))
        #expect(shortcut.label == "⇧⌘K")
    }

    @Test @MainActor func registrationFailurePreservesOldBinding() throws {
        let owner = ClipboardHotKey(identifier: 201), blocker = ClipboardHotKey(identifier: 202)
        let probe = ClipboardHotKey(identifier: 203)
        defer { owner.stop(); blocker.stop(); probe.stop() }
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        try #require(owner.register(key: UInt32(kVK_F18), modifiers: modifiers))
        try #require(blocker.register(key: UInt32(kVK_F19), modifiers: modifiers))
        #expect(!owner.register(key: UInt32(kVK_F19), modifiers: modifiers))
        #expect(!probe.register(key: UInt32(kVK_F18), modifiers: modifiers))
        owner.stop()
        #expect(probe.register(key: UInt32(kVK_F18), modifiers: modifiers))
        probe.stop()
        for action in [ScreenshotController.ShortcutAction.copy, .download] {
            let name = "QuickRegistration." + UUID().uuidString
            let defaults = try #require(UserDefaults(suiteName: name))
            let controller = ScreenshotController(defaults: defaults)
            defer { controller.stop(); defaults.removePersistentDomain(forName: name) }
            let old = RecordedShortcut(key: UInt32(kVK_F18), modifiers: modifiers, label: "⌃⌥⌘F18")
            #expect(controller.commitShortcut(old, for: action))
            #expect(!controller.commitShortcut(
                RecordedShortcut(key: UInt32(kVK_F19), modifiers: modifiers, label: "⌃⌥⌘F19"), for: action))
            #expect(controller.shortcut(for: action)?.key == old.key)
            #expect(controller.shortcut(for: action)?.modifiers == old.modifiers)
            #expect(controller.shortcut(for: action)?.label == old.label)
            #expect(!probe.register(key: old.key, modifiers: old.modifiers))
            controller.setShortcutRecording(true)
            #expect(probe.register(key: old.key, modifiers: old.modifiers))
            probe.stop()
            // 恢复只注册专用测试组合，避免测试占用系统默认截图组合。
            defaults.set(Int(kVK_F16), forKey: "screenshotKey")
            defaults.set(Int(kVK_F17), forKey: "pinKey")
            defaults.set(Int(modifiers), forKey: "screenshotModifiers")
            defaults.set(Int(modifiers), forKey: "pinModifiers")
            controller.setShortcutRecording(false)
            #expect(!probe.register(key: old.key, modifiers: old.modifiers))
            controller.clearShortcut(for: action)
            #expect(controller.shortcut(for: action) == nil)
            #expect(probe.register(key: old.key, modifiers: old.modifiers))
            probe.stop()
        }
    }

    @Test @MainActor func conflictDoesNotPersistAndCancellationResumes() throws {
        let name = "ShortcutTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "screenshotHotKeysEnabled")
        defaults.set(1, forKey: "screenshotKey")
        let controller = ScreenshotController(defaults: defaults)
        var transitions: [Bool] = []
        controller.shortcutRecordingChanged = { transitions.append($0) }
        defer { controller.stop() }
        controller.setShortcutRecording(true)
        #expect(!controller.commitShortcut(RecordedShortcut(key: 35, modifiers: UInt32(controlKey | shiftKey), label: "⌃⇧P"), for: .capture))
        #expect(defaults.integer(forKey: "screenshotKey") == 1)
        defaults.set(Int(kVK_ANSI_K), forKey: "pinKey")
        defaults.set(0, forKey: "pinModifiers")
        #expect(!controller.commitShortcut(
            RecordedShortcut(key: UInt32(kVK_ANSI_K), modifiers: 0, label: "K"), for: .capture))
        #expect(defaults.integer(forKey: "screenshotKey") == 1)
        controller.setShortcutRecording(false)
        #expect(transitions == [true, false])
        #expect(!defaults.bool(forKey: "screenshotHotKeysEnabled"))
    }

    @Test @MainActor func commandEquivalentCommitsOnModifierRelease() throws {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 80),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = ShortcutRecorder.RecorderButton()
        window.contentView = button
        defer { window.close() }
        var saved: RecordedShortcut?
        var transitions: [Bool] = []
        button.commit = { saved = $0; return true }
        button.changed = { transitions.append($0) }
        button.performClick(nil)
        #expect(button.recording)
        let down = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "K",
            charactersIgnoringModifiers: "k", isARepeat: false, keyCode: UInt16(kVK_ANSI_K)))
        #expect(button.performKeyEquivalent(with: down))
        #expect(saved == nil)
        let release = try #require(NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(kVK_Command)))
        button.flagsChanged(with: release)
        #expect(saved?.label == "⇧⌘K")
        #expect(!button.recording)
        #expect(transitions == [true, false])
        button.performClick(nil)
        button.finish()
        #expect(saved?.label == "⇧⌘K")
        #expect(transitions == [true, false, true, false])
    }

    @Test @MainActor func escapeRecordsAndClickCancels() throws {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 80),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let button = ShortcutRecorder.RecorderButton()
    window.contentView = button
    defer { window.close() }
    var saved: RecordedShortcut?
    var transitions: [Bool] = []
    button.commit = { saved = $0; return true }
    button.changed = { transitions.append($0) }
    button.performClick(nil)
    for type in [NSEvent.EventType.keyDown, .keyUp] {
        let event = try #require(NSEvent.keyEvent(with: type, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_Escape)))
        if type == .keyDown { button.keyDown(with: event); #expect(saved == nil) }
        else { button.keyUp(with: event) }
    }
    #expect(saved?.label == "Esc")
    button.performClick(nil)
    button.performClick(nil)
    #expect(!button.recording)
    #expect(saved?.label == "Esc")
    #expect(transitions == [true, false, true, false])
}

@Test @MainActor func unnamedKeyHasPhysicalLabel() throws {
    let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 10))
    #expect(RecordedShortcut(event: event)?.label == "按键 10")
}

    @Test @MainActor func permissionUsesCurrentSystemResult() {
        var allowed = false
        let controller = ScreenshotController(screenCaptureAccess: { allowed })
        controller.refreshScreenCapturePermission()
        #expect(!controller.screenCaptureAuthorized)
        allowed = true
        controller.refreshScreenCapturePermission()
        #expect(controller.screenCaptureAuthorized)
        allowed = false
        controller.refreshScreenCapturePermission()
        #expect(!controller.screenCaptureAuthorized)
    }
@Test @MainActor func quickShortcutsStartUnassignedAndRejectExistingCapture() throws {
    let name = "QuickShortcutTests." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.set(1, forKey: "screenshotKey")
    defaults.set(Int(controlKey | shiftKey), forKey: "screenshotModifiers")
    let controller = ScreenshotController(defaults: defaults)
    defer { controller.stop(); defaults.removePersistentDomain(forName: name) }
    #expect(controller.shortcut(for: .copy) == nil)
    #expect(controller.shortcut(for: .download) == nil)
    let duplicate = RecordedShortcut(key: 1, modifiers: UInt32(controlKey | shiftKey), label: "⌃⇧S")
    #expect(!controller.commitShortcut(duplicate, for: .copy))
    #expect(!controller.commitShortcut(duplicate, for: .download))
    #expect(defaults.object(forKey: "screenshotCopyKey") == nil)
    #expect(defaults.object(forKey: "screenshotDownloadKey") == nil)
    defaults.set(8, forKey: "screenshotCopyKey")
    defaults.set(Int(controlKey | optionKey), forKey: "screenshotCopyModifiers")
    #expect(!controller.commitShortcut(
        RecordedShortcut(key: 8, modifiers: UInt32(controlKey | optionKey), label: "⌃⌥C"), for: .download))
    #expect(!controller.commitShortcut(
        RecordedShortcut(key: 9, modifiers: UInt32(controlKey | shiftKey), label: "⌃⇧V"), for: .copy))

}

@Test @MainActor func fiveHotKeyIdentifiersStayIsolated() {
    let keys = (UInt32(1)...5).map { ClipboardHotKey(identifier: $0) }
    defer { keys.forEach { $0.stop() } }
    for id in UInt32(1)...5 {
        let event = EventHotKeyID(signature: 0x46424350, id: id)
        for (index, key) in keys.enumerated() { #expect(key.matches(event) == (index + 1 == Int(id))) }
    }
}

@Test @MainActor func clearingQuickBindingPreservesExistingPreferences() throws {
    let name = "QuickShortcutClear." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.set(false, forKey: "screenshotHotKeysEnabled")
    for (prefix, key, label) in [("screenshot", 1, "⌃⇧S"), ("pin", 35, "⌃⇧P"), ("screenshotCopy", 8, "⌃⌥C")] {
        defaults.set(key, forKey: prefix + "Key")
        defaults.set(Int(controlKey | shiftKey), forKey: prefix + "Modifiers")
        defaults.set(label, forKey: prefix + "KeyLabel")
    }
    let old = ["screenshot", "pin"].flatMap { prefix in ["Key", "Modifiers", "KeyLabel"].map { prefix + $0 } }
    let values = old.map { defaults.object(forKey: $0) as? NSObject }
    let controller = ScreenshotController(defaults: defaults)
    defer { controller.stop(); defaults.removePersistentDomain(forName: name) }
    controller.clearShortcut(for: .copy)
    for suffix in ["Key", "Modifiers", "KeyLabel"] { #expect(defaults.object(forKey: "screenshotCopy" + suffix) == nil) }
    for (key, value) in zip(old, values) { #expect((defaults.object(forKey: key) as? NSObject) == value) }
    #expect(controller.shortcut(for: .download) == nil)
}

}
