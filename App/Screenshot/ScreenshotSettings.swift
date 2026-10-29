import SwiftUI

struct ScreenshotSettings: View {
    @Bindable var controller: ScreenshotController
    @AppStorage("screenshotHotKeysEnabled") private var enabled = true

    @AppStorage("screenshotKeyLabel") private var snipLabel = ""
    @AppStorage("pinKeyLabel") private var pinLabel = ""

    @AppStorage("screenshotCopyKeyLabel") private var copyLabel = ""
    @AppStorage("screenshotDownloadKeyLabel") private var downloadLabel = ""

    var body: some View {
        Group {
        SettingsSection("截图") {
            HStack {
                Button("区域截图") { controller.capture(.region) }
                Button("窗口截图") { controller.capture(.window) }
                Menu("全屏截图") {
                    ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { index, screen in
                        Button("\(index + 1) · \(screen.localizedName)") { controller.capture(.screen(index + 1)) }
                    }
                }
            }.disabled(controller.capturing)
            HStack {
                Button("截图并复制") { controller.capture(.region, action: .copy) }
                Button("截图并下载") { controller.capture(.region, action: .download) }
            }.disabled(controller.capturing)
            Text("选完区域直接复制，或弹出另存为对话框保存 PNG，不打开标注编辑器。")
                .font(.caption).foregroundStyle(.secondary)
            Text("区域截图使用箭头指针，拖动选择，Escape 取消；按住 Control 松开鼠标可直接复制。截图完成后可标注、复制、另存 PNG 或贴图。")
                .font(.caption).foregroundStyle(.secondary)
            Label(controller.screenCaptureAuthorized ? "屏幕录制 · 已启用" : "屏幕录制 · 未启用",
                  systemImage: controller.screenCaptureAuthorized ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(controller.screenCaptureAuthorized ? PreferencesPalette.primary : Color.secondary)
            if !controller.screenCaptureAuthorized {
                Button("打开屏幕录制权限设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
                }
            }
        }
        SettingsSection("全局快捷键") {
            SettingsToggle(title: "启用截图与贴图快捷键", isOn: $enabled)
            shortcut("截图", label: snipLabel, action: .capture)
            shortcut("贴图", label: pinLabel, action: .paste)
            shortcut("截图并复制", label: copyLabel, action: .copy)
            shortcut("截图并下载", label: downloadLabel, action: .download)
            Text(controller.shortcutMessage).font(.caption).foregroundStyle(.secondary)
            Text("点击后直接录入单键或组合键，再次点击或移开焦点取消。冲突时保留原设置。全局单键可能影响日常输入。")
                .font(.caption).foregroundStyle(.secondary)
        }
        SettingsSection("贴图") {
            Button("将剪贴板图片贴到屏幕", action: controller.paste)
            HStack {
                Button("隐藏 / 显示全部", action: controller.togglePins)
                Button("恢复显示并取消穿透", action: controller.restorePins)
                Button("关闭全部贴图", action: controller.closePins)
            }.disabled(controller.pins.isEmpty)
            Text("拖动标题栏移动；窗口内可缩放、旋转、翻转和调整透明度。贴图仅保留至关闭或退出应用，最多 10 张、合计四千万像素。")
                .font(.caption).foregroundStyle(.secondary)
            Text(controller.message).font(.caption).foregroundStyle(.secondary)
        }
        }
        .onAppear { controller.refreshScreenCapturePermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshScreenCapturePermission()
        }
        .onDisappear { controller.setShortcutRecording(false) }
        .onChange(of: enabled) { controller.configureShortcuts() }
    }

    private func shortcut(_ title: String, label: String,
                          action: ScreenshotController.ShortcutAction) -> some View {
        HStack {
            Text(title).frame(width: 100, alignment: .leading)
            ShortcutRecorder(display: label.isEmpty ? controller.shortcut(for: action)?.label ?? "未设置" : label,
                onRecordingChanged: controller.setShortcutRecording,
                onCommit: { controller.commitShortcut($0, for: action) })
                .frame(maxWidth: .infinity).frame(height: 28)
            if action == .copy || action == .download {
                Button("清除") { controller.clearShortcut(for: action) }
                    .disabled(controller.shortcut(for: action) == nil)
            }
        }
    }
}
