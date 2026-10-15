import SwiftUI

@main
struct FastBudoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("FastBudo") { ArchiveView(model: delegate.model) }
    }
}

struct ArchiveView: View {
    @Bindable var model: ArchiveModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "archivebox").font(.largeTitle).foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("FastBudo").font(.title2.bold())
                    Text("轻量压缩 · 干净分享").foregroundStyle(.secondary)
                }
                Spacer()
                Button("打开压缩包…", action: model.chooseArchives)
            }
            if !model.residualWorkspaces.isEmpty {
                Button("查看上次中断任务的临时目录（不会自动删除）") {
                    NSWorkspace.shared.activateFileViewerSelecting(model.residualWorkspaces.map { URL(fileURLWithPath: $0) })
                }
            }
            Form {
                HStack {
                    Text(model.files.isEmpty ? "尚未选择文件" : "已选择 \(model.files.count) 个项目")
                    Spacer()
                    Button("选择文件…", action: model.chooseFiles)
                }
                TextField("名称（无需扩展名）", text: $model.name)
                Picker("格式", selection: $model.format) {
                    ForEach(ArchiveFormat.allCases, id: \.self) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
                if model.format != .tarGz {
                    SecureField("密码（可选）", text: $model.password)
                    if !model.password.isEmpty {
                        Text(model.format == .zip ? "ZIP 文件名仍可见；部分系统自带解压器不支持 AES 加密。" : "7z 会同时加密文件名。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("过滤 .DS_Store", isOn: $model.excludeDSStore)
                Toggle("保留 Mac 属性", isOn: $model.preserveAttributes)
                    .disabled(model.format != .zip || !model.password.isEmpty)
                Text("默认不携带 Mac 专有属性；普通隐藏文件仍会保留。属性保留仅支持无密码 ZIP。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text(model.outputDirectory.path).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("保存到…", action: model.chooseOutput)
                }
            }
            .formStyle(.grouped)
            .onChange(of: model.format) {
                if model.format == .tarGz { model.password = "" }
                if model.format != .zip { model.preserveAttributes = false }
            }
            .onChange(of: model.password) { if !model.password.isEmpty { model.preserveAttributes = false } }
            HStack {
                if model.busy { ProgressView().controlSize(.small) }
                Text(model.message).font(.callout).textSelection(.enabled)
                Spacer()
                if model.busy { Button("取消", action: model.cancel) }
            }
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
            HStack {
                Text(model.pending.isEmpty ? "文件处理完全在本机完成" : "还有 \(model.pending.count) 个任务排队")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("开始压缩", action: model.submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.files.isEmpty || model.name.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .onChange(of: model.results.first) {
            if let result = model.results.first { NSWorkspace.shared.activateFileViewerSelecting([result]) }
        }
        .padding(24)
        .frame(width: 560, alignment: .leading)
        .frame(minHeight: 600)
    }
}
