import AppKit
import Observation

/// 仅管理自身占位项，其他应用的顺序由用户通过系统拖动调整。
@MainActor @Observable final class MenuBarController: NSObject {
    var enabled: Bool {
        didSet {
            defaults.set(enabled, forKey: "menuBarEnabled")
            guard running, enabled != oldValue else { return }
            if enabled { createItems(); expand() } else { removeItems() }
        }
    }
    var collapseOnLaunch: Bool {
        didSet { defaults.set(collapseOnLaunch, forKey: "menuBarCollapseOnLaunch") }
    }
    private(set) var isCollapsed = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let statusBar: NSStatusBar?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var toggleItem: NSStatusItem?
    @ObservationIgnored private var dividerItem: NSStatusItem?

    // 测试传 nil，避免自动测试改变用户真实菜单栏的布局。
    init(defaults: UserDefaults = .standard, statusBar: NSStatusBar? = .system) {
        self.defaults = defaults
        self.statusBar = statusBar
        enabled = defaults.bool(forKey: "menuBarEnabled")
        collapseOnLaunch = defaults.bool(forKey: "menuBarCollapseOnLaunch")
        super.init()
    }

    func start() {
        guard !running else { return }
        running = true
        guard enabled else { return }
        createItems()
        isCollapsed = collapseOnLaunch
        updateLayout()
    }

    @objc func toggle() {
        guard running, enabled else { return }
        isCollapsed.toggle()
        updateLayout()
    }

    func expand() {
        isCollapsed = false
        updateLayout()
    }

    func stop() {
        removeItems()
        running = false
    }

    private func createItems() {
        guard toggleItem == nil, let statusBar else { return }
        let toggle = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        toggle.autosaveName = "FastBudo.MenuBar.Toggle"
        toggle.isVisible = true
        toggle.button?.target = self
        toggle.button?.action = #selector(self.toggle)
        toggleItem = toggle
        let divider = statusBar.statusItem(withLength: 26)
        divider.autosaveName = "FastBudo.MenuBar.Divider"
        divider.isVisible = true
        divider.button?.title = "│"
        divider.button?.alignment = .right
        divider.button?.toolTip = "按住 ⌘ 拖动图标：左侧收纳，右侧常驻"
        divider.button?.setAccessibilityLabel("FastBudo 收纳分隔标记")
        dividerItem = divider
        updateLayout()
    }

    private func updateLayout() {
        // shortcut: 宽占位方案依赖菜单栏布局，系统升级后需重新实测。
        dividerItem?.length = isCollapsed ? 10000 : 26
        let label = isCollapsed ? "展开收纳区" : "收起收纳区"
        toggleItem?.button?.image = NSImage(systemSymbolName: isCollapsed ? "chevron.left" : "chevron.right",
                                            accessibilityDescription: label)
        toggleItem?.button?.toolTip = label
        toggleItem?.button?.setAccessibilityLabel(label)
    }

    private func removeItems() {
        expand()
        if let toggleItem { statusBar?.removeStatusItem(toggleItem) }
        if let dividerItem { statusBar?.removeStatusItem(dividerItem) }
        toggleItem = nil
        dividerItem = nil
    }
}
