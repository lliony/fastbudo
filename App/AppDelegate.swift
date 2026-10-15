import AppKit
import SwiftUI

@MainActor @Observable final class EntryState {
    var action = "等待 Finder 服务请求"
    var files: [URL] = []
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = EntryState()
    private let services = ServicesProvider()

    func applicationDidFinishLaunching(_ notification: Notification) {
        services.receive = { [weak self] files, action in self?.receive(files, action: action) }
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        receive(urls.filter(\.isFileURL), action: "打开压缩包")
    }

    private func receive(_ files: [URL], action: String) {
        state.files = files
        state.action = action
        NSApp.activate()
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
    }
}
