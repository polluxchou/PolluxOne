import Foundation

@MainActor
@Observable
final class ScriptListViewModel {
    var scripts: [Script] = []
    var isLoading = false
    var errorMessage: String?

    private let syncService: ScriptSyncService

    init(syncService: ScriptSyncService) {
        self.syncService = syncService
    }

    func onAppear() async {
        isLoading = true
        await syncService.refreshScripts()
        scripts = syncService.scripts
        errorMessage = syncService.lastError
        isLoading = false
    }

    func refresh() async {
        await syncService.refreshScripts()
        scripts = syncService.scripts
        errorMessage = syncService.lastError
    }
}
