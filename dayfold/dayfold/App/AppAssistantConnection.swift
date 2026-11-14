import Foundation
import CalendarPlatform

extension AppModel {
    func refreshAssistantConnection() async {
        guard !assistantConfigurationBusy, let store = assistantCredentialStore else { return }
        let generation = sessionGeneration
        assistantConfigurationBusy = true
        defer { if generation == sessionGeneration { assistantConfigurationBusy = false } }
        do {
            let hasKey = try await store.load() != nil
            guard generation == sessionGeneration else { return }
            assistantKeyPresent = hasKey
            updateAssistantConnectionStatus()
        } catch {
            guard generation == sessionGeneration else { return }
            assistantKeyPresent = false
            assistantConfigurationMessage = error.localizedDescription
            assistantAvailability = .init(available: false, message: error.localizedDescription)
        }
    }

    func saveAssistantKey(_ text: String) async -> Bool {
        guard !assistantConfigurationBusy, let store = assistantCredentialStore else { return false }
        let generation = sessionGeneration
        assistantConfigurationBusy = true
        defer { if generation == sessionGeneration { assistantConfigurationBusy = false } }
        do {
            let key = try AssistantAPIKey(text.trimmingCharacters(in: .whitespacesAndNewlines))
            let composedRequest = assistantInput
            resetAssistant()
            assistantInput = composedRequest
            try await store.save(key)
            guard generation == sessionGeneration else { return false }
            assistantKeyPresent = true
            assistantConfigurationMessage = "API key saved in Keychain. It will be checked when you send your first request."
            updateAssistantConnectionStatus()
            return true
        } catch {
            guard generation == sessionGeneration else { return false }
            assistantConfigurationMessage = error.localizedDescription
            return false
        }
    }

    func removeAssistantKey() async {
        guard !assistantConfigurationBusy, let store = assistantCredentialStore else { return }
        let generation = sessionGeneration
        assistantConfigurationBusy = true
        defer { if generation == sessionGeneration { assistantConfigurationBusy = false } }
        resetAssistant()
        do {
            try await store.delete()
            guard generation == sessionGeneration else { return }
            assistantKeyPresent = false
            assistantConfigurationMessage = "API key removed from this store."
            updateAssistantConnectionStatus()
        } catch {
            guard generation == sessionGeneration else { return }
            assistantConfigurationMessage = error.localizedDescription
        }
    }

    private func updateAssistantConnectionStatus() {
        assistantAvailability = .init(available: assistantKeyPresent,
            message: assistantKeyPresent ? "Requests use your saved OpenAI API key." : "Connect your OpenAI API key to ask Dayfold for help.")
    }
}
