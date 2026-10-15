import SwiftUI

@main
struct FastBudoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("FastBudo · 入口验证") {
            VStack(alignment: .leading, spacing: 12) {
                Text(delegate.state.action).font(.headline)
                Text("当前为入口验证版本，尚不执行压缩或解压。")
                    .foregroundStyle(.secondary)
                List(delegate.state.files, id: \.self) { file in
                    Text(file.path).textSelection(.enabled)
                }
            }
            .padding(20)
            .frame(minWidth: 480, minHeight: 260)
        }
    }
}
