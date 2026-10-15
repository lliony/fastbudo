import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ArchiveModel()
    private var taskWindow: NSWindow?
    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        services.receive = { [weak self] files, action in
            self?.model.select(files, quick: action == "快捷 ZIP")
            self?.showTask(options: action != "快捷 ZIP")
        }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        model.open(urls.filter(\.isFileURL))
        showTask(options: false)
    }
    // 明确持有任务窗口，避免把 Finder 请求错误地送进设置窗口。
    private func showTask(options: Bool) {
        if taskWindow == nil {
            taskWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            taskWindow?.isReleasedWhenClosed = false
            taskWindow?.center()
        }
        taskWindow?.title = options ? "更多压缩选项" : "FastBudo 任务"
        if options {
            taskWindow?.contentViewController = NSHostingController(rootView: ArchiveView(model: model))
        } else {
            taskWindow?.contentViewController = NSHostingController(rootView: TaskStatusView(model: model).padding(24).frame(width: 400))
        }
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
