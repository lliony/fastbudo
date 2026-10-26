import SwiftUI
import FinderSync
import ApplicationServices

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

/// 设置页使用独立的明亮配色，不改变其他浮窗的外观。
enum PreferencesPalette {
    static let primary = Color(hue: 2.0 / 360, saturation: 0.835, brightness: 0.808)
    static let background = Color(white: 1)
    static let surface = Color(hue: 2.0 / 360, saturation: 0.02, brightness: 1)
    static let selection = Color(hue: 2.0 / 360, saturation: 0.06, brightness: 1)
    static let border = Color(hue: 2.0 / 360, saturation: 0.08, brightness: 0.95)
    static let secondaryText = Color(white: 0.4)
}

/// 统一设置分组的留白与换行，长内容随外层滚动，不压缩操作控件。
struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(PreferencesPalette.secondaryText)
                .padding(.horizontal, 3)
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .font(.callout)
            .labeledContentStyle(SettingsValueStyle())
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(PreferencesPalette.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(PreferencesPalette.border, lineWidth: 0.5) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 离开 Form 后仍保留设置项左右对齐的阅读顺序。
private struct SettingsValueStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            configuration.label
            Spacer(minLength: 12)
            configuration.content.multilineTextAlignment(.trailing)
        }
    }
}

/// 保留原生开关及其无障碍标签，并把操作位置固定在行尾。
struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Text(title).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PreferencesView: View {
    @Bindable var clipboard: ClipboardController
    let installUpdate: (UpdateInstaller.Prepared) async throws -> Void
    @AppStorage("excludeDSStore") private var excludeDSStore = true
    @AppStorage("preserveAttributes") private var preserveAttributes = false
    @AppStorage(NewItemTypes.key, store: NewItemTypes.defaults) private var newFileTypes = "txt, md"
    @State private var page = "通用"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var finderEnabled = false
    @State private var renameEnabled = false
    @State private var loginItemEnabled = false
    @State private var loginItemNeedsApproval = false
    @State private var loginItemError: String?
    @State private var installingUpdate = false
    @State private var updateProgress: UpdateInstaller.Progress = .manifest
    @State private var updateOperation: UUID?
    @State private var checkingUpdate = false
    @State private var updateDialogPresented = false
    @State private var updateError: String?
    @State private var availableRelease: UpdateChecker.Release?
    private let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 44, height: 44).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("FastBudo").font(.title2.weight(.semibold)).fontDesign(.rounded)
                    Text("文件小事，轻松搞定。").font(.callout).foregroundStyle(PreferencesPalette.secondaryText)
                }
                Spacer()
            }.padding(.horizontal, 20).padding(.vertical, 18)
            Picker("设置分类", selection: $page) {
                Text("通用").tag("通用")
                Text("压缩与解压").tag("压缩与解压")
                Text("新建").tag("新建")
                Text("剪贴板").tag("剪贴板")
            }
            .pickerStyle(.segmented).labelsHidden()
                .padding(4)
                .background(PreferencesPalette.selection, in: RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 20).padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if page == "剪贴板" {
                        ClipboardSettings(controller: clipboard)
                    } else if page == "通用" {
                        SettingsSection("使用方式") {
                            LabeledContent("发起操作", value: "Finder 右键 → FastBudo 压缩")
                            if finderEnabled {
                                Label("Finder 右键扩展 · 已启用", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(PreferencesPalette.primary)
                            } else {
                                Button("启用 Finder 右键扩展…") { FIFinderSyncController.showExtensionManagementInterface() }
                            }
                            LabeledContent("查看任务", value: "菜单栏 ⌘ 图标")
                            Text("在子菜单选择 ZIP、7z 或 tar.gz 后直接执行。未启用扩展时，可使用右键“服务”中的格式入口。")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        SettingsSection("版本更新") {
                            HStack {
                                LabeledContent("当前版本", value: currentVersion)
                                Button(checkingUpdate ? "正在检查…" : "检查更新") {
                                    updateError = nil
                                    availableRelease = nil
                                    checkingUpdate = true
                                }
                                .disabled(checkingUpdate || installingUpdate)
                            }
                            Text("手动检查 GitHub 正式版，更新完成后自动重启。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        SettingsSection("本机运行") {
                            SettingsToggle(title: "开机自动启动", isOn: loginItemBinding)
                            if loginItemNeedsApproval {
                                Button("在系统设置中允许…") { LoginItem.openSystemSettings() }
                                Text("macOS 需要确认后才允许开机自动启动。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Text("登录 macOS 后自动驻留菜单栏，不弹出窗口。")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("文件在本机处理。收起窗口不影响任务；退出前请先取消任务，等待清理完成。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if page == "压缩与解压" {
                        SettingsSection("压缩 · 默认选项") {
                            LabeledContent("压缩格式", value: "在 Finder 右键子菜单中选择")
                            LabeledContent("初始保存位置", value: "原文件所在文件夹")
                            Text("选择格式后立即执行，不弹出选项窗口、不设密码。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        SettingsSection("压缩 · 元数据") {
                            SettingsToggle(title: "过滤 .DS_Store", isOn: $excludeDSStore)
                            SettingsToggle(title: "保留 Mac 属性", isOn: $preserveAttributes)
                            Text("仅无密码 ZIP 支持保留属性。普通隐藏文件仍会保留，源文件不会被修改。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        SettingsSection("解压 · 输出规则") {
                            LabeledContent("保存位置", value: "压缩包所在文件夹")
                            LabeledContent("解压内容", value: "放入独立文件夹")
                            LabeledContent("遇到重名", value: "自动编号，保留已有文件")
                        }
                        SettingsSection("解压 · 安全处理") {
                            Text("大体积或无法预估的归档会在解压前请求确认。")
                            Text("拒绝不安全路径、冲突文件名、链接及特殊文件。需要密码时，在任务窗口输入后重试。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if page == "新建" {
                        SettingsSection("常用文件类型") {
                            LabeledContent("扩展名") {
                                TextField("例如 txt, md", text: $newFileTypes)
                                    .textFieldStyle(.roundedBorder).labelsHidden()
                                .multilineTextAlignment(.leading)
                                    .onChange(of: newFileTypes) { NewItemTypes.broadcast() }
                            }
                            Text("用逗号分隔，例如 txt, md, json, py。支持字母和数字，最多 12 项。保持应用运行，重新打开右键菜单后生效。")
                                .font(.caption).foregroundStyle(.secondary)
                            LabeledContent("菜单中显示", value: NewItemTypes.parse(newFileTypes).joined(separator: "、"))
                        }
                        SettingsSection("Finder 原地重命名") {
                            if renameEnabled {
                                Label("Finder 原地重命名 · 已启用", systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(PreferencesPalette.primary)
                            } else {
                                Button("允许 Finder 原地重命名…") { FinderRename.requestPermission() }
                            }
                            Text("需要在系统设置 → 隐私与安全性 → 辅助功能中允许 FastBudo。未授权时会选中新项目，可手动按回车改名。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        SettingsSection("创建规则") {
                            Text("在 Finder 当前文件夹的空白处右键 → FastBudo 新建。")
                            Text("创建后直接在 Finder 中修改名称。回车确认，Esc 保留默认名；重名自动编号。")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 20)
            }
            .id(page)
            .transition(.opacity.combined(with: .offset(y: 4)))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: page)
            Divider().overlay(PreferencesPalette.border)
            HStack {
                Label("设置自动保存", systemImage: "checkmark.circle")
                Spacer()
                Text("FastBudo · 本机处理")
            }
            .font(.caption).foregroundStyle(PreferencesPalette.secondaryText)
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(PreferencesPalette.surface)
        }
        .frame(width: 560, height: 600)
        .background(PreferencesPalette.background)
        .tint(PreferencesPalette.primary)
        .toggleStyle(.switch)
        .controlSize(.small)
        .preferredColorScheme(.light)
        .sheet(isPresented: $updateDialogPresented) { updateDialog }
        .task(id: installingUpdate) {
            guard installingUpdate, let release = availableRelease else { return }
            let operation = UUID()
            updateOperation = operation
            defer {
                if updateOperation == operation { installingUpdate = false; updateOperation = nil }
            }
            let destination = Bundle.main.bundleURL
            let preparation = Task.detached {
                try await UpdateInstaller.prepare(release: release, destination: destination) { progress in
                    Task { @MainActor in
                        guard updateOperation == operation, progress.order >= updateProgress.order else { return }
                        updateProgress = progress
                    }
                }
            }
            do {
                let update = try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                do {
                    try Task.checkCancellation()
                } catch {
                    try? FileManager.default.removeItem(at: update.workspace)
                    throw error
                }
                updateProgress = .installing
                updateDialogPresented = false
                try await installUpdate(update)
            } catch {
                if !Task.isCancelled {
                    updateError = "更新失败：\(error.localizedDescription)"
                    updateDialogPresented = true
                }
            }
        }
        .task(id: checkingUpdate) {
            guard checkingUpdate else { return }
            defer { checkingUpdate = false }
            do {
                let release = try await UpdateChecker.check(current: currentVersion)
                availableRelease = release
                updateDialogPresented = true
            } catch {
                if !Task.isCancelled {
                    updateError = "检查失败：\(error.localizedDescription)"
                    updateDialogPresented = true
                }
            }
        }
        .onAppear(perform: refreshEnabledStates)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshEnabledStates()
        }
        .alert("开机自动启动设置失败", isPresented: Binding(
            get: { loginItemError != nil },
            set: { if !$0 { loginItemError = nil } }
        )) {
            Button("好") { loginItemError = nil }
        } message: {
            Text(loginItemError ?? "")
        }
    }

    private var updateDialog: some View {
        VStack(spacing: 20) {
            Text("版本更新").font(.headline)
            if installingUpdate {
                ProgressView(value: updateProgress.fraction).progressViewStyle(.linear)
                    .accessibilityLabel(updateProgress.title)
                Text(updateProgress.title)
                Text(updateProgress.detail ?? "步骤 \(updateProgress.order + 1) / 6")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            } else if let updateError {
                Text(updateError)
            } else if let release = availableRelease {
                Text("发现新版本 \(release.tag)，当前版本为 \(currentVersion)。是否立即更新？")
                VStack(alignment: .leading, spacing: 8) {
                    Text("本次更新").font(.subheadline.bold())
                    if let notes = release.notes {
                        ScrollView {
                            Text(notes)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 180)
                    } else {
                        Text("暂未获取到更新说明，可前往发布页查看。")
                            .foregroundStyle(.secondary)
                    }
                    Link("查看完整更新说明", destination: release.url)
                }
                .multilineTextAlignment(.leading)
            } else {
                Text("当前已是最新版本（\(currentVersion)）。")
            }
            HStack {
                Spacer()
                Button(installingUpdate ? "取消" : "关闭") {
                    installingUpdate = false
                    updateDialogPresented = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(installingUpdate && updateProgress == .installing)
                if availableRelease != nil && updateError == nil && !installingUpdate {
                    Button("立即更新") { updateProgress = .manifest; installingUpdate = true }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(24)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .interactiveDismissDisabled(installingUpdate)


    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginItemEnabled },
            set: { enabled in
                do {
                    try LoginItem.setEnabled(enabled)
                } catch {
                    loginItemError = error.localizedDescription
                }
                // 无论成败都回读系统状态，失败时开关自然回弹。
                refreshEnabledStates()
            }
        )
    }

    private func refreshEnabledStates() {
        // 每次返回应用重新读取系统状态，避免撤销授权后仍显示已启用。
        finderEnabled = FIFinderSyncController.isExtensionEnabled
        renameEnabled = AXIsProcessTrusted()
        let loginItemStatus = LoginItem.status
        loginItemEnabled = loginItemStatus == .enabled
        loginItemNeedsApproval = loginItemStatus == .requiresApproval
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
