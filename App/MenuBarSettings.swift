import SwiftUI

struct MenuBarSettings: View {
    @Bindable var controller: MenuBarController
    var body: some View {
        Section("图标收纳") {
            Toggle("启用菜单栏收纳", isOn: $controller.enabled)
            Toggle("启动时收起", isOn: $controller.collapseOnLaunch)
                .disabled(!controller.enabled)
            LabeledContent("当前状态", value: !controller.enabled ? "未启用" : controller.isCollapsed ? "已收起" : "已展开")
            Button("展开收纳区", action: controller.expand)
                .disabled(!controller.enabled)
        }
        Section("调整位置与顺序") {
            Text("展开后按住 ⌘ 拖动图标。分隔标记 │ 左侧收纳，右侧常驻。")
            Text("请将收纳箭头和 FastBudo 入口留在分隔标记右侧。点击箭头展开或收起，图标顺序由系统管理。")
                .font(.callout).foregroundStyle(.secondary)
        }
        Section("恢复显示") {
            Text("找不到收纳按钮时，重新打开 FastBudo，在此点击“展开收纳区”。关闭收纳功能或正常退出也会恢复显示。")
            Text("部分系统图标不能移动；屏幕空间不足时，展开也可能无法显示全部图标。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
