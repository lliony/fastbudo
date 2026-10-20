import SwiftUI
import AppKit

struct ClipboardPanel: View {
    @Bindable var controller: ClipboardController
    @State private var replyEditor = false
    @State private var replyID: UUID?
    @State private var replyTitle = ""
    @State private var replyText = ""
    @State private var replyGroup = ""
    @State private var manageGroups = false
    @State private var newGroup = ""
    @FocusState private var searchFocused: Bool
    @AppStorage("clipCopyOnClick") private var copyOnClick = true
    @AppStorage("clipCloseAfterAction") private var closeAfterAction = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索内容、文件名或快捷回复", text: $controller.query)
                        .textFieldStyle(.plain).focused($searchFocused)
                }.padding(10).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                Button {
                    controller.setEnabled(!controller.enabled)
                } label: {
                    Label(controller.enabled ? "记录中" : "已暂停", systemImage: controller.enabled ? "pause.circle" : "play.circle")
                }.buttonStyle(.plain).help(controller.enabled ? "暂停记录" : "开启记录")
            }.padding(16)
            HStack(spacing: 20) {
                ForEach(["全部", "历史", "收藏", "快捷回复", "堆栈"], id: \.self) { section in
                    Button { controller.section = section } label: {
                        Text(section).fontWeight(controller.section == section ? .semibold : .regular)
                            .foregroundStyle(controller.section == section ? .primary : .secondary)
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) {
                                if controller.section == section { Capsule().fill(Color.accentColor).frame(height: 3) }
                            }
                    }.buttonStyle(.plain).accessibilityAddTraits(controller.section == section ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }.padding(.horizontal, 18)
            Divider()
            HStack {
                Picker("类型", selection: $controller.kind) {
                    Text("所有类型").tag("")
                    ForEach(ClipKind.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.labelsHidden().frame(width: 120)
                Picker("分组", selection: $controller.group) {
                    Text("所有分组").tag("")
                    ForEach(controller.groups, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 130)
                Spacer()
                Text("\(controller.visible.count) 条记录").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            List(selection: $controller.selected) {
                ForEach(controller.visible) { item in
                    HStack(spacing: 14) {
                        HStack(spacing: 12) {
                            Image(systemName: item.kind.symbol).font(.title2).foregroundStyle(.secondary).frame(width: 32)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.label.isEmpty ? "空文本" : item.label).lineLimit(2)
                                HStack(spacing: 6) {
                                    Text(item.source).lineLimit(1)
                                    Text("·")
                                    Text(item.used, style: .relative).lineLimit(1)
                                    if item.pinned { Image(systemName: "pin.fill").accessibilityLabel("已置顶") }
                                }.font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.contentShape(Rectangle())
                            .onTapGesture { controller.selected = item.id; if controller.copyOnClick { controller.copy(item.id) } }
                        HStack(spacing: 10) {
                            rowButton("拷贝", symbol: "square.on.square") { controller.copy(item.id) }
                                .disabled(controller.copying)
                            rowButton("收藏", symbol: item.favorite ? "star.fill" : "star", highlighted: item.favorite) {
                                controller.work { try $0.update(item.id, favorite: !item.favorite) }
                            }.accessibilityLabel(item.favorite ? "取消收藏" : "收藏")
                            rowButton("删除", symbol: "trash") { controller.delete([item.id]) }
                        }
                    }.padding(.vertical, 9).tag(item.id)
                        .listRowSeparator(.visible)
                        .contextMenu { actions(item) }
                }
            }.listStyle(.plain)
                .overlay {
                    if controller.visible.isEmpty {
                        ContentUnavailableView(controller.query.isEmpty ? "暂无记录" : "没有匹配的记录",
                            systemImage: controller.query.isEmpty ? "clipboard" : "magnifyingglass",
                            description: Text(controller.query.isEmpty ? (controller.enabled ? "新复制的内容会显示在这里。" : "点击右上角“已暂停”开启记录。") : "试试其他关键词或筛选条件。"))
                    }
                }
            Divider()
            HStack {
                Menu("管理") {
                    Button("查看所选条目…") { controller.showDetail = true }.disabled(controller.selected == nil)
                    Divider()
                    Button("新建快捷回复…") { edit(nil) }
                    Button("管理分组…") { manageGroups = true }
                    Divider()
                    Button("导出本地备份…", action: controller.exportBackup)
                    Button("导入本地备份…", action: controller.importBackup)
                    Button("删除当前筛选记录…") { controller.delete(Set(controller.visible.map(\.id))) }
                }.fixedSize()
                if controller.section == "堆栈" {
                    Button("反转", action: controller.reverseQueue).disabled(controller.queue.isEmpty)
                }
                Spacer()
                Picker("拷贝格式", selection: $controller.mode) {
                    ForEach(ClipMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(width: 195)
            }.padding(.horizontal, 16).padding(.top, 12)
            HStack {
                Text(controller.message).lineLimit(2)
                Spacer(minLength: 8)
                Text(copyOnClick ? (closeAfterAction ? "单击拷贝并关闭" : "单击拷贝") : "单击选择 · 回车拷贝")
            }.font(.caption).foregroundStyle(.secondary).padding(12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(controller.loading)
        .frame(minWidth: 480, minHeight: 400)
        .onAppear { searchFocused = true }
        .task(id: controller.query) {
            if !controller.query.isEmpty {
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
            }
            await controller.reload()
        }
        .onChange(of: controller.section) { controller.selected = controller.visible.first?.id }
        .onChange(of: controller.group) { controller.selected = controller.visible.first?.id }
        .onChange(of: controller.kind) { controller.selected = controller.visible.first?.id }
        .onKeyPress(.escape) { controller.hide(); return .handled }
        .onKeyPress(.return) { guard !replyEditor && !manageGroups && !controller.showDetail else { return .ignored }; if let id = controller.selected { controller.copy(id); return .handled }; return .ignored }
        .background {
            ForEach(1...9, id: \.self) { number in
                Button("") { if controller.visible.count >= number { controller.copy(controller.visible[number - 1].id) } }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command).hidden().accessibilityHidden(true)
            }
        }
        .sheet(isPresented: $controller.showDetail, onDismiss: { controller.clearDetail() }) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("内容详情").font(.headline)
                    Spacer()
                    Button("完成") { controller.showDetail = false }.keyboardShortcut(.cancelAction)
                }
                ScrollView {
                    if let image = controller.detailImage {
                        Image(image, scale: 1, label: Text("剪贴板图片预览")).resizable().scaledToFit()
                    } else if let payload = controller.detail {
                        if payload.kind == .files {
                            ForEach(payload.fileURLs, id: \.self) { url in
                                Text(url.path).textSelection(.enabled)
                                if !FileManager.default.fileExists(atPath: url.path) { Text("源文件已不存在").foregroundStyle(.secondary) }
                            }
                        } else {
                            Text(payload.plainText.isEmpty ? "没有可用的纯文本预览。" : String(payload.plainText.prefix(100000)))
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else { ProgressView() }
                }.frame(minHeight: 180, maxHeight: 340)
                if let item = controller.items.first(where: { $0.id == controller.selected }) {
                    Picker("分组", selection: Binding(get: { item.group }, set: { group in controller.work { try $0.update(item.id, group: group) } })) {
                        Text("未分组").tag("")
                        ForEach(controller.groups, id: \.self) { Text($0).tag($0) }
                    }
                }
            }.padding(20).frame(width: 420).task { await controller.loadDetail() }
        }
        .sheet(isPresented: $replyEditor, onDismiss: { replyText = ""; controller.clearDetail() }) {
            VStack(alignment: .leading, spacing: 14) {
                Text(replyID == nil ? "新建快捷回复" : "编辑快捷回复").font(.headline)
                TextField("标题", text: $replyTitle)
                Picker("分组", selection: $replyGroup) {
                    Text("未分组").tag("")
                    ForEach(controller.groups, id: \.self) { Text($0).tag($0) }
                }
                TextEditor(text: $replyText).frame(height: 180).border(.quaternary).accessibilityLabel("回复内容")
                HStack {
                    Button("取消") { replyEditor = false }
                    Spacer()
                    Button("保存") {
                        let id = replyID, title = replyTitle, text = replyText, group = replyGroup, policy = controller.policy
                        controller.work({ try $0.reply(id: id, title: title, text: text, group: group, policy: policy) },
                                        onSuccess: { replyEditor = false })
                    }.disabled(replyText.isEmpty).keyboardShortcut(.defaultAction)
                }
                Text(controller.message).font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(width: 440).disabled(controller.loading)
        }
        .sheet(isPresented: $manageGroups) {
            VStack(alignment: .leading, spacing: 14) {
                Text("管理分组").font(.headline)
                Text("删除分组只移除分类，不删除记录。").font(.caption).foregroundStyle(.secondary)
                List(controller.groups, id: \.self) { group in
                    HStack { Text(group); Spacer(); Button("移除") { controller.group = ""; controller.work { try $0.deleteGroup(group) } } }
                }.frame(height: 180)
                HStack {
                    TextField("新分组名称", text: $newGroup)
                    Button("新增") { let name = newGroup; controller.work { try $0.addGroup(name) }; newGroup = "" }.disabled(newGroup.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Button("完成") { manageGroups = false }.frame(maxWidth: .infinity, alignment: .trailing)
            }.padding(24).frame(width: 420)
        }
    }
    private func rowButton(_ title: String, symbol: String, highlighted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 17))
                Text(title).font(.caption2)
            }.foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
                .frame(width: 32, height: 42).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
    @ViewBuilder private func actions(_ item: ClipboardItem) -> some View {
        Button("拷贝") { controller.copy(item.id) }
        Button("查看详情…") { controller.selected = item.id; controller.showDetail = true }
        Button(item.favorite ? "取消收藏" : "收藏") { controller.work { try $0.update(item.id, favorite: !item.favorite) } }
        Button(item.pinned ? "取消置顶" : "置顶") { controller.work { try $0.update(item.id, pinned: !item.pinned) } }
        Button(item.queued ? "从堆栈移除" : "加入堆栈") { controller.enqueue(item) }
        if item.reply {
            Button("编辑快捷回复…") { edit(item) }
            Button("上移") { controller.moveReply(item, by: -1) }
            Button("下移") { controller.moveReply(item, by: 1) }
        }
        Button("删除…", role: .destructive) { controller.delete([item.id]) }
    }
    private func edit(_ item: ClipboardItem?) {
        replyID = item?.id; replyTitle = item?.title ?? ""; replyGroup = item?.group ?? ""; replyText = ""
        if let item {
            controller.selected = item.id
            Task { await controller.loadDetail(); guard controller.selected == item.id, let detail = controller.detail else { return }; replyText = detail.plainText; controller.clearDetail(); replyEditor = true }
        } else { replyEditor = true }
    }
}
