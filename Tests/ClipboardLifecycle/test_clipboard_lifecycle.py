"""使用生产面板验证后台唤起；隔离剪贴板和数据库，不修改用户设置。"""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''
import AppKit
import Carbon
@main enum Probe {
    @MainActor static func main() {
        let app = NSApplication.shared
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FASTBUDO_PROBE_ROOT"]!)
        if ProcessInfo.processInfo.environment["FASTBUDO_FOREGROUND"] == "1" {
            app.setActivationPolicy(.regular)
            let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1500, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
            window.title = "前台验证窗口"
            let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let marker = root.appendingPathComponent("activate")
                    if FileManager.default.fileExists(atPath: marker.path) {
                        try? FileManager.default.removeItem(at: marker)
                        window.makeKeyAndOrderFront(nil)
                        app.activate(ignoringOtherApps: true)
                        try? Data(String(window.windowNumber).utf8).write(to: root.appendingPathComponent("foreground-window"))
                    }
                }
            }
            withExtendedLifetime((window, timer)) { app.run() }
            return
        }
        app.setActivationPolicy(.accessory)
        let suite = "FastBudoProbe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "clipEnabled")
        defaults.set(8, forKey: "clipHotKeyCode")
        defaults.set(Int(controlKey | optionKey | shiftKey), forKey: "clipHotKeyModifiers")
        let board = NSPasteboard.withUniqueName()
        let clipboard = ClipboardController(defaults: defaults, board: board, directory: root.appendingPathComponent("clipboard"))
        let delegate = AppDelegate(clipboard: clipboard)
        DispatchQueue.main.async {
            clipboard.start()
            Task { @MainActor in
                defer {
                    clipboard.hide(); clipboard.stop(); board.releaseGlobally()
                    defaults.removePersistentDomain(forName: suite)
                    app.terminate(nil)
                }
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    app.delegate = delegate
                    for stage in ["cold", "closed", "existing"] {
                        if stage != "cold" {
                            delegate.showSettings()
                            try await Task.sleep(for: .milliseconds(300))
                            if stage == "closed" {
                                delegate.settingsWindow!.close()
                                try await Task.sleep(for: .milliseconds(500))
                            }
                        }
                        try Data().write(to: root.appendingPathComponent("activate"))
                        for _ in 0..<100 {
                            if !app.isActive && !FileManager.default.fileExists(atPath: root.appendingPathComponent("activate").path) { break }
                            try await Task.sleep(for: .milliseconds(20))
                        }
                        guard !app.isActive else { throw CocoaError(.validationMissingMandatoryProperty) }
                        // 通过 Carbon 事件目标走生产快捷键回调，不占用或注入用户的默认快捷键。
                        var event: EventRef?
                        CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event)
                        var hotKeyID = EventHotKeyID(signature: 0x46424350, id: 1)
                        SetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &hotKeyID)
                        let result = SendEventToEventTarget(event, GetApplicationEventTarget())
                        ReleaseEvent(event)
                        try await Task.sleep(for: .milliseconds(400))
                        let panel = app.windows.first { $0.title == "FastBudo 剪贴板" }
                        let onScreen = panel?.occlusionState.contains(.visible) == true
                        let key = panel?.isKeyWindow == true
                        let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] ?? []
                        let numbers = windows.compactMap { $0[kCGWindowNumber as String] as? Int }
                        let foregroundNumber = Int(try String(contentsOf: root.appendingPathComponent("foreground-window"), encoding: .utf8))!
                        let foregroundIndex = numbers.firstIndex(of: foregroundNumber) ?? -1
                        let settingsIndex = delegate.settingsWindow.flatMap { numbers.firstIndex(of: $0.windowNumber) }
                        let panelIndex = panel.flatMap { numbers.firstIndex(of: $0.windowNumber) } ?? Int.max
                        let panelInFront = foregroundIndex >= 0 && panelIndex < foregroundIndex
                        let settingsStayedBehind = settingsIndex.map { foregroundIndex >= 0 && $0 > foregroundIndex } ?? true
                        let settingsOK = stage == "existing" ? delegate.settingsWindow?.isKeyWindow == false : delegate.settingsWindow?.isVisible != true
                        let report = "\(stage): event=\(result) visible=\(clipboard.isPanelVisible) screen=\(onScreen) key=\(key) active=\(app.isActive) settingsOK=\(settingsOK) behind=\(settingsStayedBehind) panelInFront=\(panelInFront)\n"
                        let url = root.appendingPathComponent(stage)
                        try Data(report.utf8).write(to: url)
                        guard result == noErr, onScreen, key, settingsOK, settingsStayedBehind, panelInFront else { return }
                        clipboard.hide()
                    }
                    try Data("passed".utf8).write(to: root.appendingPathComponent("passed"))
                } catch { try? Data(error.localizedDescription.utf8).write(to: root.appendingPathComponent("error")) }
            }
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
'''


class ClipboardLifecycleTests(unittest.TestCase):
    def test_background_hotkey_without_settings_activation(self):
        with tempfile.TemporaryDirectory(prefix="fastbudo-clipboard-test-") as directory:
            root = Path(directory)
            app = root / "Probe.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "local.fastbudo.clipboard-probe",
                "CFBundleExecutable": "Probe", "CFBundlePackageType": "APPL", "LSUIElement": True,
            }))
            app_source = root / "FastBudoApp.swift"
            app_source.write_text((ROOT / "App/FastBudoApp.swift").read_text().replace("@main\n", "", 1))
            harness = root / "Probe.swift"
            harness.write_text(HARNESS)
            sources = [str(p) for p in (ROOT / "App").rglob("*.swift") if p.name != "FastBudoApp.swift"]
            sources += [str(p) for p in (ROOT / "Shared").glob("*.swift")]
            binary = app / "Contents/MacOS/Probe"
            subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", *sources,
                            str(app_source), str(harness), "-lsqlite3", "-o", str(binary)], check=True)
            foreground_app = root / "Foreground.app"
            shutil.copytree(app, foreground_app)
            info = foreground_app / "Contents/Info.plist"
            metadata = plistlib.loads(info.read_bytes())
            metadata["CFBundleIdentifier"] = "local.fastbudo.foreground-probe"
            info.write_bytes(plistlib.dumps(metadata))
            foreground = subprocess.Popen([str(foreground_app / "Contents/MacOS/Probe")], env=dict(os.environ, FASTBUDO_PROBE_ROOT=str(root), FASTBUDO_FOREGROUND="1"))
            try:
                subprocess.run([str(binary)], env=dict(os.environ, FASTBUDO_PROBE_ROOT=str(root)), timeout=20, check=True)
            finally:
                foreground.terminate()
                foreground.wait(timeout=5)
            reports = "".join(p.read_text() for p in root.iterdir() if p.name in {"cold", "closed", "existing", "error"})
            self.assertTrue((root / "passed").exists(), reports)
            print(reports)


if __name__ == "__main__":
    unittest.main()
