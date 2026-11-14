import Foundation
import CalendarCore
import CalendarPlatform

extension AppModel {
    func resetLocalStore(exportFirst: Bool) {
        Task {
            let generation = sessionGeneration
            if exportFirst { guard await exportRecovery() else { return } }
            do {
                guard generation == sessionGeneration, let repository else { throw CalendarError.missing }
                resetAssistant()
                try await assistantCredentialStore?.delete()
                guard generation == sessionGeneration else { throw CalendarError.staleGeneration }
                assistantKeyPresent = false; assistantAvailability = nil
                let resettingAccounts = accounts, scheduler = notifications, demo = isDemo, directory = dataDirectory, authorizer = auth
                if relayConfiguration != nil { try await disconnectRelay() }
                guard generation == sessionGeneration else { throw CalendarError.staleGeneration }
                // Invalidate every account before removing credentials or cached rows.
                for var account in resettingAccounts { account.generation += 1; account.status = .removing; try await repository.updateAccount(account) }
                for account in resettingAccounts {
                    if !demo { try await authorizer.remove(account.id) }
                    await scheduler?.removeAllForAccount(account.id)
                    try await repository.removeAccount(account.id, discardPending: true)
                }
                try await repository.clearDisconnectedStore()
                if demo, let directory { try? FileManager.default.removeItem(at: directory.appendingPathComponent("provider.json")) }
                guard generation == sessionGeneration else { return }
                unsavedDrafts = [:]; editingDraft = nil; quickText = ""; queuedRedo = nil; reversalRequest = nil; preferences = Preferences()
                await reload()
            } catch { if generation == sessionGeneration { errorMessage = "Local reset stopped so remaining data can be recovered. " + error.localizedDescription } }
        }
    }
}
