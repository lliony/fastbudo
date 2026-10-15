import AppKit

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ArchiveModel()
    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        services.receive = { [weak self] files, action in
            self?.model.select(files, quick: action == "快捷 ZIP")
            NSApp.activate()
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        model.open(urls.filter(\.isFileURL))
        NSApp.activate()
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
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
