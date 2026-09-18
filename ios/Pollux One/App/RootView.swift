import SwiftUI

struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        Group {
            if environment.currentUser != nil {
                RecordingView(
                    script: environment.sessionManager.scriptRevision?.script,
                    sessionManager: environment.sessionManager
                )
            } else {
                LoginView()
            }
        }
        .task { await environment.restoreSession() }
    }
}
