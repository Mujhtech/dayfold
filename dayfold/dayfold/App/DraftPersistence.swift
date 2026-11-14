import Foundation
import CalendarCore

extension AppModel {
    func retainDraftForSave(_ draft: EventDraft) { unsavedDrafts[draft.id] = draft }
    func persistDraft(_ draft: EventDraft) async throws {
        guard let repository else { throw CalendarError.unavailable("The local store is unavailable. Your text is still in the editor.") }
        try await repository.saveDraft(draft)
        if unsavedDrafts[draft.id]?.updated == draft.updated { unsavedDrafts[draft.id] = nil }
    }
    func discardDraft(_ id: String) async throws {
        guard let repository else { throw CalendarError.missing }
        try await repository.discardDraft(id)
        unsavedDrafts[id] = nil
        completeAssistantDraft(id, message: "Draft discarded. No event was added.")
    }
    func flushLocalDrafts() async throws {
        for draft in unsavedDrafts.values { try await persistDraft(draft) }
        if !quickText.isEmpty {
            try await repository?.saveDraft(EventDraft(id: "quick-entry-text", calendar: preferences.defaultCalendar, fields: ["summary": .string(quickText), "quickInput": .string(quickText)]))
        }
    }
}
