"""用真实 SwiftUI sheet 验证退出、目录替换和新进程启动；仅操作独立临时应用。"""
import os
from pathlib import Path
import plistlib
import shlex
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''
import AppKit
import SwiftUI
struct ProbeView: View {
    let delegate: AppDelegate
    let update: UpdateInstaller.Prepared
    @State var shown = true
    var body: some View {
        Text("更新验证").sheet(isPresented: $shown) {
            Text("安装中").padding().interactiveDismissDisabled(true)
        }.task {
            do {
                for _ in 0..<100 where delegate.settingsWindow?.attachedSheet == nil {
                    try await Task.sleep(for: .milliseconds(20))
                }
                guard delegate.settingsWindow?.attachedSheet != nil else { throw CocoaError(.validationMissingMandatoryProperty) }
                try Data("visible".utf8).write(to: update.workspace.deletingLastPathComponent().appendingPathComponent("sheet-visible"))
                shown = false
                try await delegate.installUpdate(update)
            } catch {
                try? Data(error.localizedDescription.utf8).write(to: update.workspace.deletingLastPathComponent().appendingPathComponent("failure"))
                if let parent = delegate.settingsWindow, let sheet = parent.attachedSheet { parent.endSheet(sheet) }
                NSApp.terminate(nil)
            }
        }
    }
}
@main enum Probe {
    @MainActor static func main() {
        let app = NSApplication.shared
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FASTBUDO_PROBE_ROOT"]!)
        let suite = "FastBudoProbe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "clipEnabled"); defaults.set(false, forKey: "clipHotKeyEnabled")
        let delegate = AppDelegate(clipboard: ClipboardController(defaults: defaults, board: .withUniqueName(), directory: root.appendingPathComponent("clipboard")))
        DispatchQueue.main.async {
            // 启动后再接入 delegate，不触发服务注册或用户配置广播。
            app.delegate = delegate
            delegate.showSettings()
            let update = UpdateInstaller.Prepared(workspace: root.appendingPathComponent("workspace"), application: root.appendingPathComponent("workspace/Staged.app"), destination: root.appendingPathComponent("Installed.app"))
            delegate.settingsWindow!.contentViewController = NSHostingController(rootView: ProbeView(delegate: delegate, update: update))
            defaults.removePersistentDomain(forName: suite)
        }
        withExtendedLifetime(delegate) { app.run() }
    }
}
'''


class UpdateLifecycleTests(unittest.TestCase):
    def test_visible_sheet_dismisses_then_replaces_and_relaunches(self):
        with tempfile.TemporaryDirectory(prefix="fastbudo-update-test-") as directory:
            root = Path(directory)
            installed = root / "Installed.app"
            staged = root / "workspace/Staged.app"
            for app, version in [(installed, "0.0.2"), (staged, "0.0.3")]:
                (app / "Contents/MacOS").mkdir(parents=True)
                (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                    "CFBundleIdentifier": "local.fastbudo.probe",
                    "CFBundleName": "FastBudo 更新验证", "CFBundleExecutable": "Probe",
                    "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
                    "LSUIElement": True,
                }))
            launcher = staged / "Contents/MacOS/Probe"
            launcher.write_text("#!/bin/sh\nprintf restarted > " + shlex.quote(str(root / "restarted")) + "\n")
            launcher.chmod(0o755)
            app_source = root / "FastBudoApp.swift"
            app_source.write_text((ROOT / "App/FastBudoApp.swift").read_text().replace("@main\n", "", 1))
            harness = root / "Probe.swift"
            harness.write_text(HARNESS)
            sources = [str(p) for p in (ROOT / "App").rglob("*.swift") if p.name != "FastBudoApp.swift"]
            sources += [str(p) for p in (ROOT / "Shared").glob("*.swift")]
            binary = installed / "Contents/MacOS/Probe"
            subprocess.run(["swiftc", "-swift-version", "6", "-parse-as-library", *sources,
                            str(app_source), str(harness), "-lsqlite3", "-o", str(binary)], check=True)
            with (root / "stderr.log").open("w") as log:
                process = subprocess.Popen([str(binary)], env=dict(os.environ, FASTBUDO_PROBE_ROOT=str(root)),
                                           stdout=subprocess.DEVNULL, stderr=log)
                try:
                    self.assertEqual(process.wait(timeout=20), 0)
                    for _ in range(100):
                        if (root / "restarted").exists():
                            break
                        time.sleep(0.1)
                    self.assertTrue((root / "sheet-visible").exists(), "必须先展示真实更新弹窗")
                    failure = root / "failure"
                    self.assertFalse(failure.exists(), failure.read_text() if failure.exists() else "")
                    self.assertTrue((root / "restarted").exists(), "新版进程必须确认启动")
                    self.assertEqual(plistlib.loads((installed / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"], "0.0.3")
                    self.assertEqual(plistlib.loads((staged / "Contents/Info.plist").read_bytes())["CFBundleShortVersionString"], "0.0.2")
                finally:
                    if process.poll() is None:
                        process.terminate()
                        process.wait(timeout=5)


if __name__ == "__main__":
    unittest.main()
