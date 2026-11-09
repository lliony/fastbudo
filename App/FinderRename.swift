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
            // 只认 Finder 前台；激活动画或权限弹窗造成的前台抖动不会中断等待。
            // 最终是否发送由下方 matches 精确判定兜底，因此中途不等 Finder 也不会误发回车。
            for _ in 0..<30 {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard !Task.isCancelled else { return }
                guard let app = NSWorkspace.shared.frontmostApplication,
                      app.bundleIdentifier == "com.apple.finder" else { continue }
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
        guard selection.count == 1 else { return false }
        return equivalent(selection.first!, to: target)
    }

    /// Finder 报告的项 URL 与本地创建的 URL 可能仅差尾斜杠、或路径经符号链接（如 /tmp）；两者都算同一目标。
    static func equivalent(_ a: URL, to b: URL) -> Bool {
        func key(_ u: URL) -> String {
            var p = u.resolvingSymlinksInPath().standardizedFileURL.absoluteString
            while p.hasSuffix("/") { p.removeLast() }
            return p
        }
        return key(a) == key(b)
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
