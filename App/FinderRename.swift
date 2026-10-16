import AppKit
@preconcurrency import ApplicationServices

/// 只向 Finder 中当前选中的新项目发送重命名按键，不发送全局按键。
@MainActor enum FinderRename {
    private static var pending: Task<Void, Never>?
    private static var requestedPermission = false

    static func requestPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func revealAndRename(_ url: URL) {
        pending?.cancel()
        NSWorkspace.shared.activateFileViewerSelecting([url])
        guard AXIsProcessTrusted() else {
            if !requestedPermission { requestedPermission = true; requestPermission() }
            return
        }
        pending = Task { @MainActor in
            var sawFinder = false
            for _ in 0..<20 {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard !Task.isCancelled else { return }
                guard let app = NSWorkspace.shared.frontmostApplication,
                      app.bundleIdentifier == "com.apple.finder" else {
                    if sawFinder { return }
                    continue
                }
                sawFinder = true
                let finder = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(finder, 0.1)
                guard let rawWindow = value(finder, kAXFocusedWindowAttribute),
                      CFGetTypeID(rawWindow) == AXUIElementGetTypeID() else { continue }
                let window = rawWindow as! AXUIElement
                let selected = selectedURLs(in: window)
                guard matches(selected, target: url) else { continue }
                // 发送前再次核对前台应用，绝不把回车送到其他应用。
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
                      !Task.isCancelled else { return }
                let source = CGEventSource(stateID: .privateState)
                let down = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: true)
                let up = CGEvent(keyboardEventSource: source, virtualKey: 36, keyDown: false)
                down?.postToPid(app.processIdentifier)
                up?.postToPid(app.processIdentifier)
                return
            }
        }
    }

    static func matches(_ selection: Set<URL>, target: URL) -> Bool {
        selection.count == 1 && selection.first?.standardizedFileURL == target.standardizedFileURL
    }

    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }

    private static func selectedURLs(in window: AXUIElement) -> Set<URL> {
        var found = Set<URL>()
        var remaining = 1500
        let deadline = Date().addingTimeInterval(0.2)
        var complete = true
        func visit(_ element: AXUIElement, selected: Bool, depth: Int) {
            guard remaining > 0, depth < 16, Date() < deadline else { complete = false; return }
            remaining -= 1
            let isSelected = (value(element, kAXSelectedAttribute) as? Bool) ?? selected
            if isSelected, let url = value(element, kAXURLAttribute) as? URL, url.isFileURL {
                found.insert(url)
            }
            for child in (value(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                visit(child, selected: isSelected, depth: depth + 1)
            }
        }
        visit(window, selected: false, depth: 0)
        // 遍历不完整时不能证明只有一个项目被选中。
        return complete ? found : []
    }
}
