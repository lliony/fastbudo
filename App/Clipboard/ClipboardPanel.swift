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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索内容、文件名或快捷回复", text: $controller.query).textFieldStyle(.plain).focused($searchFocused)
                Button(controller.enabled ? "暂停记录" : "开启记录") { controller.setEnabled(!controller.enabled) }
            }.padding(16)
            HStack {
                Picker("范围", selection: $controller.section) {
                    ForEach(["全部", "历史", "收藏", "快捷回复", "堆栈"], id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.segmented)
                Picker("类型", selection: $controller.kind) {
                    Text("所有类型").tag("")
                    ForEach(ClipKind.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.frame(width: 125)
                Picker("分组", selection: $controller.group) {
                    Text("所有分组").tag("")
                    ForEach(controller.groups, id: \.self) { Text($0).tag($0) }
                }.frame(width: 140)
            }.padding(.horizontal, 16).padding(.bottom, 12)
            Divider()
            HSplitView {
                List(selection: $controller.selected) {
                    ForEach(controller.visible) { item in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.kind.symbol).foregroundStyle(.secondary).frame(width: 22)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.label.isEmpty ? "空文本" : item.label).lineLimit(2)
                                HStack(spacing: 8) {
                                    Text(item.source)
                                    Text(item.used, style: .relative)
                                    if !item.group.isEmpty { Text(item.group) }
                                    if item.favorite { Image(systemName: "star.fill").accessibilityLabel("已收藏") }
                                    if item.pinned { Image(systemName: "pin.fill").accessibilityLabel("已置顶") }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5).tag(item.id)
                        .contextMenu { actions(item) }
                        .onTapGesture(count: 2) { controller.use(item.id, paste: true) }
                    }
                }.frame(minWidth: 320)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let item = controller.items.first(where: { $0.id == controller.selected }) {
                            HStack {
                                Text(item.kind.title).font(.headline)
                                Spacer()
                                Button { var value = item; value.favorite.toggle(); controller.update(value) } label: {
                                    Image(systemName: item.favorite ? "star.fill" : "star")
                                }.help("收藏").accessibilityLabel("切换收藏")
                                Button { var value = item; value.pinned.toggle(); controller.update(value) } label: {
                                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                                }.help("置顶").accessibilityLabel("切换置顶")
                            }
                            if let payload = controller.detail {
                                if payload.kind == .image,
                                   let data = payload.items.first?["public.png"] ?? payload.items.first?["public.tiff"], let image = NSImage(data: data) {
                                    Image(nsImage: image).resizable().scaledToFit().accessibilityLabel("剪贴板图片预览")
                                } else if payload.kind == .files {
                                    ForEach(payload.fileURLs, id: \.self) { url in
                                        Text(url.path).textSelection(.enabled)
                                        if !FileManager.default.fileExists(atPath: url.path) { Text("源文件已不存在").foregroundStyle(.secondary) }
                                    }
                                } else {
                                    Text(payload.plainText.isEmpty ? "包含富文本表示；没有可用的纯文本预览。" : String(payload.plainText.prefix(100000)))
                                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else { ProgressView() }
                            Divider()
                            Text("来源：\(item.source) · \(item.created.formatted())").font(.caption).foregroundStyle(.secondary)
                            Picker("分组", selection: Binding(get: { item.group }, set: { group in var value = item; value.group = group; controller.update(value) })) {
                                Text("未分组").tag("")
                                ForEach(controller.groups, id: \.self) { Text($0).tag($0) }
                            }
                        } else {
                            ContentUnavailableView("暂无记录", systemImage: "clipboard", description: Text(controller.enabled ? "复制新的内容后会显示在这里。" : "点击“开启记录”后，仅记录新复制的内容。"))
                        }
                    }.padding(18)
                }.frame(minWidth: 280)
            }
            Divider()
            HStack {
                Menu("管理") {
                    Button("新建快捷回复…") { edit(nil) }
                    Button("管理分组…") { manageGroups = true }
                    Divider()
                    Button("导出本地备份…", action: controller.exportBackup)
                    Button("导入本地备份…", action: controller.importBackup)
                    Button("删除当前筛选记录…") { controller.delete(Set(controller.visible.map(\.id))) }
                }
                if controller.section == "堆栈" {
                    Button("反转", action: controller.reverseQueue)
                    Button("粘贴首条") { if let item = controller.queue.first { controller.use(item.id, paste: true) } }.disabled(controller.queue.isEmpty)
                }
                Spacer()
                Picker("输出", selection: $controller.mode) { ForEach(ClipMode.allCases, id: \.self) { Text($0.title).tag($0) } }.frame(width: 155)
                Button("复制") { if let id = controller.selected { controller.use(id, paste: false) } }.disabled(controller.selected == nil)
                Button("粘贴") { if let id = controller.selected { controller.use(id, paste: true) } }
                    .buttonStyle(.borderedProminent).disabled(controller.selected == nil)
            }.padding(.horizontal, 16).padding(.top, 12)
            Text("粘贴目标：\(controller.targetName) · \(controller.message)").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(12)
        }
        .disabled(controller.loading)
        .frame(minWidth: 720, minHeight: 420)
        .onAppear { searchFocused = true }
        .task(id: controller.query) { await controller.reload() }
        .task(id: controller.selected) { await controller.loadDetail() }
        .onChange(of: controller.section) { controller.selected = controller.visible.first?.id }
        .onChange(of: controller.group) { controller.selected = controller.visible.first?.id }
        .onChange(of: controller.kind) { controller.selected = controller.visible.first?.id }
        .onKeyPress(.escape) { controller.hide(); return .handled }
        .onKeyPress(.return) { if let id = controller.selected { controller.use(id, paste: true); return .handled }; return .ignored }
        .background {
            ForEach(1...9, id: \.self) { number in
                Button("") { if controller.visible.count >= number { controller.use(controller.visible[number - 1].id, paste: true) } }
                    .keyboardShortcut(KeyEquivalent(Character(String(number))), modifiers: .command).hidden().accessibilityHidden(true)
            }
        }
        .sheet(isPresented: $replyEditor) {
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
    @ViewBuilder private func actions(_ item: ClipboardItem) -> some View {
        Button("复制") { controller.use(item.id, paste: false) }
        Button("粘贴") { controller.use(item.id, paste: true) }
        Button(item.favorite ? "取消收藏" : "收藏") { var value = item; value.favorite.toggle(); controller.update(value) }
        Button(item.pinned ? "取消置顶" : "置顶") { var value = item; value.pinned.toggle(); controller.update(value) }
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
            Task { await controller.loadDetail(); guard controller.selected == item.id else { return }; replyText = controller.detail?.plainText ?? ""; replyEditor = true }
        } else { replyEditor = true }
    }
}
