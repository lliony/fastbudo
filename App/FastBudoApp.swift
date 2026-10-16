import SwiftUI
import FinderSync

@main
struct FastBudoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra("FastBudo", systemImage: "command") {
            StatusPopover(model: delegate.model, showSettings: delegate.showSettings, showClipboard: delegate.clipboard.show)
        }
        .menuBarExtraStyle(.window)
    }
}

struct PreferencesView: View {
    @Bindable var clipboard: ClipboardController
    @AppStorage("excludeDSStore") private var excludeDSStore = true
    @AppStorage("preserveAttributes") private var preserveAttributes = false
    @AppStorage(NewItemTypes.key, store: NewItemTypes.defaults) private var newFileTypes = "txt, md"
    @State private var page = "压缩与解压"
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 48, height: 48).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("FastBudo").font(.title2.bold())
                    Text("让日常操作更顺手").foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(24)
            Picker("设置分类", selection: $page) {
                Text("通用").tag("通用")
                Text("压缩与解压").tag("压缩与解压")
                Text("新建").tag("新建")
                Text("剪贴板").tag("剪贴板")
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24)
            Form {
                if page == "剪贴板" {
                    ClipboardSettings(controller: clipboard)
                } else if page == "通用" {
                    Section("使用方式") {
                        LabeledContent("发起操作", value: "Finder 右键 → FastBudo 压缩")
                        Button("启用 Finder 右键扩展…") { FIFinderSyncController.showExtensionManagementInterface() }
                        LabeledContent("查看任务", value: "菜单栏 ⌘ 图标")
                        Text("在子菜单选择 ZIP、7z 或 tar.gz 后直接执行。未启用扩展时，可使用右键“服务”中的格式入口。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Section("本机运行") {
                        Text("文件处理完全在本机完成。关闭任务窗口或收起浮窗，任务仍会继续。")
                        Text("任务执行时请先取消，等待清理完成后退出应用。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if page == "压缩与解压" {
                    Section("压缩 · 默认选项") {
                        LabeledContent("压缩格式", value: "在 Finder 右键子菜单中选择")
                        LabeledContent("初始保存位置", value: "原文件所在文件夹")
                        Text("选择格式后立即执行，不弹出选项窗口、不设密码。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("压缩 · 元数据") {
                        Toggle("过滤 .DS_Store", isOn: $excludeDSStore)
                        Toggle("保留 Mac 属性", isOn: $preserveAttributes)
                        Text("仅无密码 ZIP 支持保留属性。普通隐藏文件仍会保留，源文件不会被修改。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Section("解压 · 输出规则") {
                        LabeledContent("保存位置", value: "压缩包所在文件夹")
                        LabeledContent("解压内容", value: "放入独立文件夹")
                        LabeledContent("遇到重名", value: "自动编号，保留已有文件")
                    }
                    Section("解压 · 安全处理") {
                        Text("大体积或无法预估的归档会在解压前请求确认。")
                        Text("拒绝不安全路径、冲突文件名、链接及特殊文件。需要密码时，在任务窗口输入后重试。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if page == "新建" {
                    Section("常用文件类型") {
                        TextField("扩展名", text: $newFileTypes)
                            .onChange(of: newFileTypes) { NewItemTypes.broadcast() }
                        Text("用逗号分隔，例如 txt, md, json, py。支持字母和数字，最多 12 项。保持应用运行，重新打开右键菜单后生效。")
                            .font(.caption).foregroundStyle(.secondary)
                        LabeledContent("菜单中显示", value: NewItemTypes.parse(newFileTypes).joined(separator: "、"))
                    }
                    Section("创建规则") {
                        Text("在 Finder 当前文件夹的空白处右键 → FastBudo 新建。")
                        Text("选择类型后输入名称，确认才创建文件或文件夹。重名自动编号，完成后在 Finder 中选中。")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                }
            }.formStyle(.grouped)
            HStack {
                Label("设置自动保存", systemImage: "checkmark.circle")
                Spacer()
                Text("FastBudo · 本地工具")
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 24).padding(.bottom, 18)
        }
        .frame(width: 600, height: 520)
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
    let showSettings: () -> Void
    let showClipboard: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("FastBudo", systemImage: "command").font(.headline)
            Button("剪贴板…", action: showClipboard)
            TaskStatusView(model: model)
            Divider()
            HStack {
                Button("设置…", action: showSettings)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
