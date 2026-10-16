import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = ArchiveModel()
    let clipboard: ClipboardController
    let menuBar: MenuBarController
    override convenience init() { self.init(clipboard: ClipboardController(), menuBar: MenuBarController()) }
    init(clipboard: ClipboardController, menuBar: MenuBarController) {
        self.clipboard = clipboard
        self.menuBar = menuBar
        super.init()
    }
    private var taskWindow: NSWindow?
    private(set) var settingsWindow: NSWindow?
    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        clipboard.start()
        menuBar.start()
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        // 只计算主窗口，菜单栏和剪贴板浮窗不需要程序坞图标。
        let hasOpenWindow = [settingsWindow, taskWindow].compactMap { $0 }.contains {
            $0 !== closing && ($0.isVisible || $0.isMiniaturized)
        }
        if !hasOpenWindow { NSApp.setActivationPolicy(.accessory) }
    }

    func showSettings() {
        NSApp.setActivationPolicy(.regular)
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "FastBudo 设置"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: PreferencesView(clipboard: clipboard, menuBar: menuBar))
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
    func createItem(in directory: URL, type: String) {
        let folder = type == "folder"
        let name = folder ? "新建文件夹" : "未命名.\(type == "custom" ? "txt" : type)"
        let alert = NSAlert()
        alert.messageText = folder ? "新建文件夹" : "新建文件"
        alert.informativeText = folder ? "输入文件夹名称。重名会自动编号。" : "输入完整文件名（包含扩展名），例如 config.json。重名会自动编号。"
        let input = NSTextField(string: name)
        input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "创建").keyEquivalent = "\r"
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        NSApp.activate()
        alert.window.initialFirstResponder = input
        // 等模态窗口建立字段编辑器后，只选中文件名主体，保留扩展名。
        RunLoop.main.perform(inModes: [.modalPanel]) {
            MainActor.assumeIsolated {
                input.selectText(nil)
                let stem = folder ? name : (name as NSString).deletingPathExtension
                (input.currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: 0, length: (stem as NSString).length))
            }
        }
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let result = try NewItem.create(in: directory, name: input.stringValue, folder: folder)
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
        NSApp.setActivationPolicy(.regular)
        if taskWindow == nil {
            taskWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            taskWindow?.isReleasedWhenClosed = false
            taskWindow?.delegate = self
            taskWindow?.center()
        }
        taskWindow?.title = "FastBudo 任务"
        taskWindow?.contentViewController = NSHostingController(rootView: TaskStatusView(model: model).padding(24).frame(width: 400))
        NSApp.activate()
        taskWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) { menuBar.stop(); clipboard.stop() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.busy else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "任务仍在执行"
        alert.informativeText = "请先取消任务，等待临时文件清理完成后退出。"
        alert.runModal()
        return .terminateCancel
    }
}
