import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = ArchiveModel()
    let clipboard: ClipboardController
    private let requestTermination: @MainActor () -> Void
    private let revealNewItem: @MainActor (URL) -> Void
    override convenience init() { self.init(clipboard: ClipboardController()) }
    init(clipboard: ClipboardController, revealNewItem: @escaping @MainActor (URL) -> Void = FinderRename.revealAndRename,
         requestTermination: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }) {
        self.requestTermination = requestTermination
        self.clipboard = clipboard
        self.revealNewItem = revealNewItem
        super.init()
    }
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
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "FastBudo 设置"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentViewController = NSHostingController(rootView: PreferencesView(clipboard: clipboard, installUpdate: installUpdate))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.deminiaturize(nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func installUpdate(_ update: UpdateInstaller.Prepared) async throws {
        var retainBackup = false
        defer {
            if !retainBackup { try? FileManager.default.removeItem(at: update.workspace) }
        }
        guard !model.busy else { throw ArchiveFailure("请等待当前压缩或解压任务完成后再更新。") }
        // 禁止交互关闭的 SwiftUI sheet 会阻止 AppKit 退出，请求退出前主动结束它。
        if let parent = settingsWindow, let sheet = parent.attachedSheet {
            parent.endSheet(sheet)
            sheet.orderOut(nil)
            // endSheet 的关闭动画异步结束；附着关系仍在时 AppKit 会忽略退出请求。
            for _ in 0..<100 where parent.attachedSheet != nil {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard parent.attachedSheet == nil else { throw ArchiveFailure("更新对话框尚未关闭，请稍后重试。") }
        }
        try Task.checkCancellation()
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", UpdateInstaller.relaunchScript, "fastbudo-relaunch",
                            String(ProcessInfo.processInfo.processIdentifier), update.destination.path,
                            update.workspace.path, "/usr/bin/open", update.application.path]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
        do {
            try UpdateInstaller.swap(update.destination, update.application)
            retainBackup = true
        } catch {
            helper.terminate()
            throw error
        }
        // terminate 可在主循环稍后完成；返回不代表拒绝退出，先给 AppKit 留出退出时间。
        // 提交安装后不再响应界面任务的取消，避免提前回滚正在退出的应用。
        let gracePeriod = Task.detached { try await Task.sleep(for: .seconds(5)) }
        DispatchQueue.main.async { [requestTermination] in requestTermination() }
        try? await gracePeriod.value
        helper.terminate()
        do {
            try UpdateInstaller.swap(update.destination, update.application)
        } catch {
            throw ArchiveFailure("恢复原版本失败，旧应用仍保留在：\(update.application.path)")
        }
        retainBackup = false
        throw ArchiveFailure("应用未能退出，已恢复原版本，请稍后重试。")
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
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try NewItem.create(in: directory, name: name, folder: folder)
                }.value
                revealNewItem(result)
            } catch {
                let alert = NSAlert()
                alert.messageText = "无法创建"
                alert.informativeText = "请检查文件名及目标文件夹的写入权限。\n\(error.localizedDescription)"
                NSApp.activate()
                alert.runModal()
            }
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
