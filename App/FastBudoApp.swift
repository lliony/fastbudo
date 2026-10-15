import SwiftUI

@main
struct FastBudoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("FastBudo 设置", id: "settings") {
            PreferencesView()
        }
        .defaultSize(width: 520, height: 380)
        .windowResizability(.contentSize)
        MenuBarExtra("FastBudo", systemImage: "archivebox") {
            StatusPopover(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct PreferencesView: View {
    @AppStorage("excludeDSStore") private var excludeDSStore = true
    @AppStorage("preserveAttributes") private var preserveAttributes = false
    @AppStorage("defaultFormat") private var defaultFormat = "zip"
    var body: some View {
        Form {
            Section("默认压缩选项") {
                Picker("格式", selection: $defaultFormat) {
                    ForEach(ArchiveFormat.allCases, id: \.rawValue) { Text($0.rawValue.uppercased()).tag($0.rawValue) }
                }
                Text("快捷压缩始终使用 ZIP；更多压缩选项可单独调整。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("元数据") {
                Toggle("过滤 .DS_Store", isOn: $excludeDSStore)
                Toggle("保留 Mac 属性", isOn: $preserveAttributes)
                Text("属性保留仅适用于无密码 ZIP。普通隐藏文件仍会保留，不修改源文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Label("从 Finder 右键服务发起压缩", systemImage: "cursorarrow")
                Text("点击菜单栏归档图标查看任务。密码在每次压缩时输入，设置自动保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 380)
    }
}

/// 任务状态由窗口和菜单栏共享，关闭浮窗不会取消任务。
struct TaskStatusView: View {
    @Bindable var model: ArchiveModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !model.pending.isEmpty {
                Text("还有 \(model.pending.count) 个任务排队").font(.caption).foregroundStyle(.secondary)
            }
            if model.busy { Button("取消任务", action: model.cancel) }
            if model.failed != nil {
                if model.requiresExpansionConfirmation {
                    Button("确认继续解压", action: model.approveExpansion)
                } else {
                    SecureField("重试密码（若需要）", text: $model.password)
                    HStack {
                        Button("重试", action: model.retry)
                        Button("更换输出位置…", action: model.chooseOutput)
                    }
                }
                Button("跳过此任务", action: model.skip)
            }
            if let result = model.results.first {
                Button("在 Finder 中显示结果") { NSWorkspace.shared.activateFileViewerSelecting([result]) }
            }
            if !model.residualWorkspaces.isEmpty {
                Button("查看中断任务的临时目录") {
                    NSWorkspace.shared.activateFileViewerSelecting(model.residualWorkspaces.map { URL(fileURLWithPath: $0) })
                }
            }
        }
    }
}

struct StatusPopover: View {
    @Bindable var model: ArchiveModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("FastBudo", systemImage: "archivebox").font(.headline)
            TaskStatusView(model: model)
            Divider()
            HStack {
                Button("设置…") { openWindow(id: "settings"); NSApp.activate() }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}

struct ArchiveView: View {
    @Bindable var model: ArchiveModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("压缩 \(model.files.count) 个项目").font(.title2.bold())
            Form {
                Picker("格式", selection: $model.format) {
                    ForEach(ArchiveFormat.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }.pickerStyle(.segmented)
                TextField("文件名", text: $model.name)
                if model.format != .tarGz {
                    SecureField("密码（可选）", text: $model.password)
                    if !model.password.isEmpty {
                        Text(model.format == .zip ? "ZIP 文件名仍可见；部分解压器不支持 AES。" : "7z 同时加密文件名。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(model.outputDirectory.path).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("保存到…", action: model.chooseOutput)
                }
            }
            .onChange(of: model.format) {
                if model.format == .tarGz { model.password = "" }
            }
            TaskStatusView(model: model)
            HStack {
                Text("仅应用于本次压缩").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("压缩", action: model.submit)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(model.files.isEmpty || model.name.isEmpty || model.busy || model.failed != nil)
            }
        }
        .padding(24).frame(width: 500)
    }
}
