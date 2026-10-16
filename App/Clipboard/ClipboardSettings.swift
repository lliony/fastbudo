import SwiftUI
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
    @AppStorage("clipCopyOnClick") private var copyOnClick = true
    @AppStorage("clipCloseAfterAction") private var closeAfterAction = true
    var body: some View {
        Section("基础设置") {
            Toggle("记录新复制的内容", isOn: $enabled).onChange(of: enabled) { controller.setEnabled(enabled) }
            Button("打开剪贴板…", action: controller.show)
            ClipboardLimitField(title: "历史记录上限", value: $count, range: 100...10000, step: 100, unit: "条")
            ClipboardLimitField(title: "保存时间", value: $days, range: 1...365, step: 1, unit: "天")
            ClipboardLimitField(title: "内容容量上限", value: $mib, range: 20...1024, step: 20, unit: "MiB")
            Text("可直接输入数值，按回车或离开输入框保存。")
                .font(.caption).foregroundStyle(.secondary)
            Button("立即按限制清理") { let policy = controller.policy; controller.work { try $0.clean(policy) } }
            Text("收藏、置顶、快捷回复和堆栈不会自动删除。容量按编码内容计算，数据库另有少量开销；单条上限 20 MiB。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("操作习惯") {
            Toggle("单击条目即拷贝", isOn: $copyOnClick)
            Text("关闭后，单击只选择条目；可使用每条右侧的拷贝按钮。")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("操作完成后关闭面板", isOn: $closeAfterAction)
            Text("拷贝成功后收起；失败时保留提示。收藏和删除不关闭面板。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("唤起快捷键") {
            Toggle("启用全局快捷键", isOn: $hotKeyEnabled).onChange(of: hotKeyEnabled) { controller.configureShortcut() }
            HStack {
                modifier("⌃", Int(controlKey)); modifier("⇧", Int(shiftKey)); modifier("⌘", Int(cmdKey)); modifier("⌥", Int(optionKey))
                Picker("按键", selection: $key) { Text("V").tag(9); Text("C").tag(8); Text("空格").tag(49) }.frame(width: 130)
            }.onChange(of: modifiers) { controller.configureShortcut() }.onChange(of: key) { controller.configureShortcut() }
            Text(controller.hotKeyMessage).font(.caption).foregroundStyle(.secondary)
            Text("面板内方向键选择、回车拷贝、⌘1–9 拷贝对应条目、Escape 收起。")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("隐私") {
            TextField("不记录的应用 Bundle ID", text: $excluded)
            TextField("禁用快捷键的应用 Bundle ID", text: $hotKeyExcluded)
            Text("多个标识用逗号分隔。来源按采集时前台应用推断；敏感标记过滤不能识别所有密码。历史仅本地保存，未加密。")
                .font(.caption).foregroundStyle(.secondary)

        }
    }
    private func modifier(_ name: String, _ mask: Int) -> some View {
        Toggle(name, isOn: Binding(get: { modifiers & mask != 0 }, set: { if $0 { modifiers |= mask } else { modifiers &= ~mask } })).toggleStyle(.checkbox)
    }
}

/// 数值草稿独立于偏好值，避免输入中间态意外触发更严格的清理限制。
private struct ClipboardLimitField: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String
    @State private var draft = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                TextField(title, text: $draft)
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing).monospacedDigit()
                    .frame(width: 90).focused($focused).onSubmit(commit)
                    .accessibilityLabel(title + "，" + unit)
                Stepper(title, value: $value, in: range, step: step).labelsHidden().fixedSize()
                Text(unit).foregroundStyle(.secondary).frame(width: 32, alignment: .leading)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { draft = String(value) }
        .onChange(of: value) { draft = String(value); error = nil }
        .onChange(of: focused) { if !focused { commit() } }
    }
    private func commit() {
        guard let number = ClipboardController.validatedLimit(draft, range: range) else {
            error = "请输入 \(range.lowerBound)–\(range.upperBound) 的整数"
            return
        }
        value = number; draft = String(number); error = nil
    }
}
