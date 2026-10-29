import AppKit
import SwiftUI
import Carbon

struct RecordedShortcut: Equatable {
    let key: UInt32
    let modifiers: UInt32
    let label: String

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        let modifiers = (flags.contains(.control) ? UInt32(controlKey) : 0)
            | (flags.contains(.option) ? UInt32(optionKey) : 0)
            | (flags.contains(.shift) ? UInt32(shiftKey) : 0)
            | (flags.contains(.command) ? UInt32(cmdKey) : 0)
        let key = UInt32(event.keyCode)
        guard ClipboardHotKey.accepts(key: key, modifiers: modifiers) else { return nil }
        let special: [UInt32: String] = [53: "Esc", 49: "空格", 36: "Return", 48: "Tab", 51: "Delete",
            117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down"]
        let name: String
        if let index = ClipboardHotKey.functionKeys.firstIndex(of: Int(key)) { name = "F\(index + 1)" }
        else if let value = special[key] { name = value }
        else {
            name = (event.charactersIgnoringModifiers ?? "").unicodeScalars
                .filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().uppercased()
        }
        self.init(key: key, modifiers: modifiers, label: Self.modifierLabel(modifiers) + (name.isEmpty ? "按键 " + String(key) : name))
    }

    init(key: UInt32, modifiers: UInt32, label: String) {
        self.key = key; self.modifiers = modifiers; self.label = label
    }

    static func modifierLabel(_ modifiers: UInt32) -> String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined()
    }
}

/// 只在主动录入时接收窗口事件，不安装全局键盘监听。
struct ShortcutRecorder: NSViewRepresentable {
    let display: String
    let onRecordingChanged: (Bool) -> Void
    let onCommit: (RecordedShortcut) -> Bool

    func makeNSView(context: Context) -> RecorderButton { RecorderButton() }
    func updateNSView(_ view: RecorderButton, context: Context) {
        view.display = display; view.changed = onRecordingChanged; view.commit = onCommit
        if !view.recording { view.title = display }
    }
    static func dismantleNSView(_ view: RecorderButton, coordinator: ()) { view.finish() }

    final class RecorderButton: NSButton {
        var display = ""
        var changed: (Bool) -> Void = { _ in }
        var commit: (RecordedShortcut) -> Bool = { _ in false }
        private(set) var recording = false
        private var candidate: RecordedShortcut?
        private var observer: NSObjectProtocol?
        override var acceptsFirstResponder: Bool { true }

        init() {
            super.init(frame: .zero)
            bezelStyle = .rounded
            target = self; action = #selector(begin)
            setAccessibilityLabel("录入快捷键")
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        @objc private func begin() {
            if recording { finish(); return }
            guard window?.makeFirstResponder(self) == true else { return }
            recording = true; title = "请按快捷键，再次点击取消"; changed(true)
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finish() }
            }
        }
        func finish() {
            guard recording else { return }
            recording = false; candidate = nil; title = display
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil; changed(false)
        }
        override func resignFirstResponder() -> Bool { finish(); return super.resignFirstResponder() }
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { finish() }
            super.viewWillMove(toWindow: newWindow)
        }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event); return true
        }
        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            guard !event.isARepeat else { return }
            candidate = RecordedShortcut(event: event)
            title = candidate?.label ?? "请按一个按键或组合键"
        }
        override func keyUp(with event: NSEvent) {
            guard recording, let candidate, candidate.key == UInt32(event.keyCode) else { return }
            complete(candidate)
        }
        private func complete(_ candidate: RecordedShortcut) {
            let accepted = commit(candidate)
            finish()
            if !accepted { title = "组合不可用，点击重试" }
        }
        override func flagsChanged(with event: NSEvent) {
            guard recording else { super.flagsChanged(with: event); return }
            // AppKit 处理 Command 等价键后可能吞掉 keyUp，松开修饰键也完成录入。
            if event.modifierFlags.intersection([.control, .option, .shift, .command]).isEmpty,
               let candidate { complete(candidate) }
        }
    }
}
