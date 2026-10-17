import ServiceManagement

/// 主应用登录项：对应设置页「登录时打开」。状态以系统为准，不留本地副本，
/// 避免与「系统设置 → 登录项」中的用户改动不一致。
enum LoginItem {
    enum Status {
        case enabled, requiresApproval, notRegistered, unavailable
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notRegistered: .notRegistered
        // .notFound 等异常态没有可执行的引导，按不可用处理。
        default: .unavailable
        }
    }

    /// 注册或注销失败同步抛错（如签名不被系统接受）；状态变化由系统异步生效，
    /// status 可能稍后才反映，调用方按下次刷新收敛。
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
