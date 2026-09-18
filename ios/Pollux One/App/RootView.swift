import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            if environment.currentUser != nil {
                // 相机仍然是根，只是外面多了一层流程容器：BriefFlow 自己不画
                // 任何东西，它把相机原样放在最底下，Brief 的屏盖上去。
                BriefFlow()
            } else {
                LoginView()
            }
        }
        .task { await environment.restoreSession() }
    }
}
