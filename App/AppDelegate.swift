import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ArchiveModel()
    private var taskWindow: NSWindow?
    private(set) var settingsWindow: NSWindow?
    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        services.receive = { [weak self] files, format in
            self?.model.compress(files, as: format)
        }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        // AppKit 区分正常启动与文件/服务唤起，避免右键压缩时抢出设置页。
        if notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true {
            showSettings()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "FastBudo 设置"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: PreferencesView())
            window.center()
            settingsWindow = window
        }
        settingsWindow?.deminiaturize(nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "fastbudo" {
            do {
                let request = try FinderRequest.read(url)
                guard let format = ArchiveFormat(rawValue: request.format) else { continue }
                model.compress(request.files, as: format)
                if let board = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "board" })?.value {
                    NSPasteboard(name: NSPasteboard.Name(board)).releaseGlobally()
                }
            } catch {
                model.message = "无法读取 Finder 选择，请重新右键选择压缩格式。"
            }
        }
        let archives = urls.filter(\.isFileURL)
        if !archives.isEmpty { model.open(archives); showTask() }
    }
    // 明确持有任务窗口，避免把 Finder 请求错误地送进设置窗口。
    private func showTask() {
        if taskWindow == nil {
            taskWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            taskWindow?.isReleasedWhenClosed = false
            taskWindow?.center()
        }
        taskWindow?.title = "FastBudo 任务"
        taskWindow?.contentViewController = NSHostingController(rootView: TaskStatusView(model: model).padding(24).frame(width: 400))
        NSApp.activate()
        taskWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "任务仍在执行"
        alert.informativeText = "请先取消任务，等待临时文件清理完成后退出。"
        alert.runModal()
        return .terminateCancel
    }
}
