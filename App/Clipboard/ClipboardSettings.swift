import SwiftUI
@preconcurrency import ApplicationServices
import Carbon

struct ClipboardSettings: View {
    @Bindable var controller: ClipboardController
    @AppStorage("clipEnabled") private var enabled = false
    @AppStorage("clipCount") private var count = 1000
    @AppStorage("clipDays") private var days = 30
    @AppStorage("clipMiB") private var mib = 200
    @AppStorage("clipExcluded") private var excluded = "com.1password.1password, com.agilebits.onepassword7, com.apple.keychainaccess"
    @AppStorage("clipHotKeyExcluded") private var hotKeyExcluded = ""
    @AppStorage("clipHotKeyEnabled") private var hotKeyEnabled = true
    @AppStorage("clipHotKeyCode") private var key = 9
    @AppStorage("clipHotKeyModifiers") private var modifiers = Int(controlKey | shiftKey)
    var body: some View {
        Section("历史记录") {
            Toggle("记录新复制的内容", isOn: $enabled).onChange(of: enabled) { controller.setEnabled(enabled) }
            Button("打开剪贴板…", action: controller.show)
            Stepper("普通历史上限：\(count) 条", value: $count, in: 100...10000, step: 100)
            Stepper("保存时间：\(days) 天", value: $days, in: 1...365)
            Stepper("内容容量上限：\(mib) MiB", value: $mib, in: 20...1024, step: 20)
            Button("立即按限制清理") { let policy = controller.policy; controller.work { try $0.clean(policy) } }
            Text("收藏、置顶、快捷回复和堆栈不会自动删除。容量按编码内容计算，数据库另有少量开销；单条上限 20 MiB。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("唤起快捷键") {
            Toggle("启用全局快捷键", isOn: $hotKeyEnabled).onChange(of: hotKeyEnabled) { controller.configureShortcut() }
            HStack {
                modifier("⌃", Int(controlKey)); modifier("⇧", Int(shiftKey)); modifier("⌘", Int(cmdKey)); modifier("⌥", Int(optionKey))
                Picker("按键", selection: $key) { Text("V").tag(9); Text("C").tag(8); Text("空格").tag(49) }.frame(width: 130)
            }.onChange(of: modifiers) { controller.configureShortcut() }.onChange(of: key) { controller.configureShortcut() }
            Text(controller.hotKeyMessage).font(.caption).foregroundStyle(.secondary)
            Text("面板内方向键选择、回车粘贴、⌘1–9 粘贴对应条目、Escape 收起。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("隐私与权限") {
            TextField("不记录的应用 Bundle ID", text: $excluded)
            TextField("禁用快捷键的应用 Bundle ID", text: $hotKeyExcluded)
            Text("多个标识用逗号分隔。来源按采集时前台应用推断；敏感标记过滤不能识别所有密码。历史仅本地保存，未加密。")
                .font(.caption).foregroundStyle(.secondary)
            Button("申请自动粘贴所需的辅助功能权限…") {
                let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
            }
            Text("未授权或不能确认输入焦点时只复制，请手动粘贴。不会申请完全磁盘访问。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    private func modifier(_ name: String, _ mask: Int) -> some View {
        Toggle(name, isOn: Binding(get: { modifiers & mask != 0 }, set: { if $0 { modifiers |= mask } else { modifiers &= ~mask } })).toggleStyle(.checkbox)
    }
}
