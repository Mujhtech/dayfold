import Foundation
import CalendarCore
import CalendarPlatform

extension AppModel {
    func resetLocalStore(exportFirst: Bool) {
        Task {
            if exportFirst { guard await exportRecovery() else { return } }
            do {
                guard let repository else { throw CalendarError.missing }
                // Invalidate every account before removing credentials or cached rows.
                for var account in accounts { account.generation += 1; account.status = .removing; try await repository.updateAccount(account) }
                for account in accounts {
                    if !isDemo { try await auth.remove(account.id) }
                    await notifications?.removeAllForAccount(account.id)
                    try await repository.removeAccount(account.id, discardPending: true)
                }
                try await repository.clearDisconnectedStore()
                unsavedDrafts = [:]; editingDraft = nil; quickText = ""; queuedRedo = nil; reversalRequest = nil; preferences = Preferences()
                if isDemo, let dataDirectory { try? FileManager.default.removeItem(at: dataDirectory.appendingPathComponent("provider.json")) }
                await reload()
            } catch { errorMessage = "Local reset stopped so remaining data can be recovered. " + error.localizedDescription }
        }
    }
}
