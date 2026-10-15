import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = ArchiveModel()
    let clipboard: ClipboardController
    override convenience init() { self.init(clipboard: ClipboardController()) }
    init(clipboard: ClipboardController) { self.clipboard = clipboard; super.init() }
    private var taskWindow: NSWindow?
    private(set) var settingsWindow: NSWindow?
    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        clipboard.start()
        services.receive = { [weak self] files, format in
            self?.model.compress(files, as: format)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(publishNewItemTypes),
            name: NewItemTypes.requested, object: nil)
        NewItemTypes.broadcast()
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
        // AppKit 区分正常启动与文件/服务唤起，避免右键压缩时抢出设置页。
        if notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool == true {
            showSettings()
        }
    }
    @objc private func publishNewItemTypes() { NewItemTypes.broadcast() }

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
            window.contentViewController = NSHostingController(rootView: PreferencesView(clipboard: clipboard))
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
                if request.action == "create" {
                    createItem(in: request.files[0], type: request.format)
                } else if let format = ArchiveFormat(rawValue: request.format) {
                    model.compress(request.files, as: format)
                }
                if let board = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "board" })?.value {
                    NSPasteboard(name: NSPasteboard.Name(board)).releaseGlobally()
                }
            } catch {
                model.message = "无法读取 Finder 选择，请重新打开右键菜单。"
            }
        }
        let archives = urls.filter(\.isFileURL)
        if !archives.isEmpty { model.open(archives); showTask() }
    }
    private func createItem(in directory: URL, type: String) {
        var name = type == "folder" ? "新建文件夹" : "未命名.\(type)"
        if type == "custom" {
            let alert = NSAlert()
            alert.messageText = "新建文件"
            alert.informativeText = "输入完整文件名（包含扩展名），例如 config.json。重名会自动编号。"
            let input = NSTextField(string: "未命名.txt")
            input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
            alert.accessoryView = input
            alert.addButton(withTitle: "创建")
            alert.addButton(withTitle: "取消")
            NSApp.activate()
            alert.window.initialFirstResponder = input
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            name = input.stringValue
        }
        do {
            let result = try NewItem.create(in: directory, name: name, folder: type == "folder")
            NSWorkspace.shared.activateFileViewerSelecting([result])
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法创建"
            alert.informativeText = "请检查文件名及目标文件夹的写入权限。\n\(error.localizedDescription)"
            NSApp.activate()
            alert.runModal()
        }
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

    func applicationWillTerminate(_ notification: Notification) { clipboard.stop() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "任务仍在执行"
        alert.informativeText = "请先取消任务，等待临时文件清理完成后退出。"
        alert.runModal()
        return .terminateCancel
    }
}
