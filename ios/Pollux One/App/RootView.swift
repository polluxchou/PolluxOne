import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            if environment.currentUser != nil {
                ScriptListView(
                    syncService: environment.syncService,
                    takeArchiver: environment.takeArchiver
                )
            } else {
                LoginView()
            }
        }
        .task { await environment.restoreSession() }
    }
}
