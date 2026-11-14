import Foundation
import CalendarCore
import CalendarPlatform

extension AppModel {
    var preferredPage: SidebarPage { preferences.experienceMode == .assistant ? .assistant : .calendar }

    func resetAssistant() {
        assistantTask?.cancel(); assistantTask = nil
        assistantRequestID = UUID()
        assistantService = nil
        assistantInput = ""; assistantQuestion = ""; assistantAnswer = ""
        assistantProposal = nil; assistantProposalZone = nil; assistantDraftID = nil
        assistantDraftStatus = nil
        assistantError = nil; assistantActivity = []
        assistantIsWorking = false; assistantIsStopping = false; assistantIsOpeningDraft = false
    }

    func cancelAssistant() {
        guard assistantIsWorking, !assistantIsStopping else { return }
        assistantIsStopping = true
        assistantTask?.cancel()
    }

    func askAssistant() {
        let question = assistantInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !assistantIsWorking, !assistantIsOpeningDraft, !assistantConfigurationBusy,
              preferences.experienceMode == .assistant, !isLoading, let repository,
              let credentialStore = assistantCredentialStore, assistantKeyPresent else { return }
        guard question.count <= 1_800 else { assistantError = "Keep your request under 1,800 characters."; return }

        let previous = assistantQuestion.isEmpty || assistantAnswer.isEmpty ? nil :
            "User: \(assistantQuestion.prefix(500))\nDayfold: \(assistantAnswer.prefix(500))"
        let generation = sessionGeneration, requestID = UUID(), requestedAt = Date()
        let zone = preferences.timeZone
        let chosenModel = preferences.assistantModel, previewDate = assistantPreviewDate
        let reader = AssistantCalendarReader(repository: repository, now: requestedAt, zone: zone,
                                             workStart: preferences.workStart, workEnd: preferences.workEnd)
        assistantRequestID = requestID
        assistantQuestion = question; assistantInput = ""; assistantAnswer = ""
        assistantProposal = nil; assistantProposalZone = nil; assistantDraftID = nil
        assistantDraftStatus = nil
        assistantError = nil; assistantActivity = []; assistantIsWorking = true
        let service = assistantService ?? CloudCalendarAssistant()
        assistantService = service

        assistantTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if assistantRequestID == requestID { assistantIsWorking = false; assistantIsStopping = false; assistantTask = nil }
            }
            do {
                guard let apiKey = try await credentialStore.load() else {
                    guard generation == sessionGeneration, requestID == assistantRequestID else { return }
                    assistantKeyPresent = false
                    assistantAvailability = .init(available: false, message: "Connect your OpenAI API key to ask Dayfold for help.")
                    throw CalendarError.unavailable("Add your OpenAI API key in Assistant settings to send a request.")
                }
                try Task.checkCancellation()
                guard generation == sessionGeneration, requestID == assistantRequestID else { return }
                let reply = try await service.respond(
                    to: question, previousExchange: previous, currentDate: requestedAt, selectedDate: previewDate, timeZone: zone,
                    workStart: reader.workStart, workEnd: reader.workEnd, apiKey: apiKey, model: chosenModel,
                    calendarDay: { [weak self] date in
                        try Task.checkCancellation()
                        let result = try await reader.calendarDay(date)
                        try Task.checkCancellation()
                        await self?.recordAssistantActivity("Read calendars for \(date)", date: date, zone: zone, requestID: requestID)
                        return result
                    },
                    freeTime: { [weak self] date, duration in
                        try Task.checkCancellation()
                        let result = try await reader.freeTime(date, duration: duration)
                        try Task.checkCancellation()
                        await self?.recordAssistantActivity("Checked \(duration)-minute openings on \(date)", date: date, zone: zone, requestID: requestID)
                        return result
                    }
                )
                try Task.checkCancellation()
                guard generation == sessionGeneration, requestID == assistantRequestID,
                      preferences.experienceMode == .assistant else { return }
                assistantAnswer = reply.text
                if let proposal = reply.proposal {
                    _ = try proposal.validatedTime(in: zone)
                    let day = try LocalDate(proposal.date)
                    let today = LocalDate(requestedAt, zone: zone)
                    guard day >= today, day <= today.adding(days: 31) else {
                        throw CalendarError.invalid("Use a date from today through the next 31 days, or create the event directly in Calendar.")
                    }
                    assistantProposal = proposal
                    assistantProposalZone = zone
                    assistantPreviewDate = day.start(in: zone)
                }
            } catch is CancellationError {
                if generation == sessionGeneration, requestID == assistantRequestID {
                    assistantError = "Stopped. No calendar changes were made."
                }
            } catch {
                guard generation == sessionGeneration, requestID == assistantRequestID else { return }
                assistantError = error.localizedDescription
            }
        }
    }

    private func recordAssistantActivity(_ activity: String, date: String, zone: TimeZone, requestID: UUID) {
        guard requestID == assistantRequestID else { return }
        if !assistantActivity.contains(activity) { assistantActivity.append(activity) }
        if let day = try? LocalDate(date) { assistantPreviewDate = day.start(in: zone) }
    }

    func completeAssistantDraft(_ id: String, message: String) {
        guard assistantDraftID == id else { return }
        assistantProposal = nil; assistantProposalZone = nil; assistantDraftID = nil
        assistantDraftStatus = message
    }

    func reviewAssistantProposal() {
        guard !assistantIsOpeningDraft, !assistantIsWorking, !isLoading, !isShowingOnboarding,
              preferences.experienceMode == .assistant, editingDraft == nil,
              let proposal = assistantProposal, let zone = assistantProposalZone, let repository else { return }
        let generation = sessionGeneration, requestID = assistantRequestID, range = visibleRange
        let existingDraftID = assistantDraftID
        assistantIsOpeningDraft = true
        Task {
            defer { if requestID == assistantRequestID { assistantIsOpeningDraft = false } }
            do {
                // Reopen the same local draft, never duplicate a proposal on repeated clicks.
                if let existingDraftID {
                    let saved = try await repository.snapshot(interval: range, displayZone: zone).drafts.first { $0.id == existingDraftID }
                    guard generation == sessionGeneration, requestID == assistantRequestID,
                          preferences.experienceMode == .assistant, !isLoading else { return }
                    if let saved {
                        guard editingDraft == nil else {
                            assistantError = "Close the current event editor before reopening this draft."
                            return
                        }
                        editingDraft = saved
                    }
                    else { completeAssistantDraft(existingDraftID, message: "That draft is closed. Saved events are in Calendar or Pending Changes.") }
                    return
                }
                let sources = try await repository.calendars()
                let identities = try await repository.accounts()
                guard generation == sessionGeneration, requestID == assistantRequestID,
                      preferences.experienceMode == .assistant, !isLoading else { return }
                guard editingDraft == nil else {
                    assistantError = "Close the current event editor before reviewing this suggestion."
                    return
                }
                let writable = sources.filter { source in
                    source.syncEnabled && !source.deleted && EventCapabilityResolver.resolve(
                        .create, account: identities.first { $0.id == source.key.account }, calendar: source
                    ).allowed
                }
                guard let source = writable.first(where: { $0.key == preferences.defaultCalendar }) ?? writable.first else {
                    throw CalendarError.permission("Choose a writable calendar in Settings before reviewing a new event.")
                }
                let draft = try proposal.draft(calendar: source.key, timeZone: zone)
                try await repository.saveDraft(draft)
                guard generation == sessionGeneration, requestID == assistantRequestID,
                      preferences.experienceMode == .assistant, !isLoading else { return }
                assistantDraftID = draft.id
                guard editingDraft == nil else {
                    assistantError = "Your suggestion is saved as a draft. Close the current event editor to review it."
                    return
                }
                editingDraft = draft
            } catch {
                guard generation == sessionGeneration, requestID == assistantRequestID else { return }
                assistantError = error.localizedDescription
            }
        }
    }
}

/// Only minimal, bounded schedule data reaches the chosen model. These
/// read tools cannot enqueue, send or delete an event.
private struct AssistantCalendarReader: Sendable {
    let repository: CalendarRepository
    let now: Date
    let zone: TimeZone
    let workStart: Int
    let workEnd: Int

    private func context(for date: String) async throws -> AssistantDayContext {
        let day = try LocalDate(date)
        guard day.description == date else { throw CalendarError.invalid("Use an exact YYYY-MM-DD date.") }
        let today = LocalDate(now, zone: zone)
        guard day >= today.adding(days: -7), day <= today.adding(days: 31) else {
            throw CalendarError.invalid("The assistant can look seven days back and 31 days ahead.")
        }
        let range = DateInterval(start: day.start(in: zone), end: day.adding(days: 1).start(in: zone))
        let snapshot = try await repository.snapshot(interval: range, displayZone: zone)
        try Task.checkCancellation()
        return try AssistantDayContext(snapshot: snapshot, day: day, timeZone: zone)
    }

    func calendarDay(_ date: String) async throws -> String {
        let day = try await context(for: date)
        let payload: JSONObject = [
            "date": .string(date), "timeZone": .string(zone.identifier),
            "scope": .string("All synchronized calendars, including calendars hidden in the sidebar. Unsynchronized calendars are excluded."),
            "completeAndFresh": .bool(day.availabilityIsReliable),
            "totalEvents": .number(Double(day.totalEventCount)),
            "eventsOmitted": .bool(day.totalEventCount > 10),
            "events": .array(day.events.prefix(10).map { event in
                .object(["title": .string(String(event.title.prefix(80))),
                         "start": .string(localTime(event.start)), "end": .string(localTime(event.end)),
                         "allDay": .bool(event.isAllDay), "busy": .bool(event.isBusy)])
            })
        ]
        return try json(payload)
    }

    func freeTime(_ date: String, duration: Int) async throws -> String {
        let day = try await context(for: date)
        guard day.day >= LocalDate(now, zone: zone) else { throw CalendarError.invalid("Choose today or a future day to find open time.") }
        do {
            let slots = try AssistantAvailability.freeSlots(in: day, durationMinutes: duration,
                workStart: workStart, workEnd: workEnd, notBefore: now)
            return try json([
                "date": .string(date), "timeZone": .string(zone.identifier), "reliable": .bool(true),
                "scope": .string("Downloaded, synchronized calendars including hidden calendars. Unsynchronized calendars are excluded."),
                "durationMinutes": .number(Double(duration)),
                "windows": .array(slots.prefix(6).map { .object(["from": .string(localTime($0.start)), "until": .string(localTime($0.end))]) }),
                "instruction": .string("Each window can fit the requested duration. A proposed event must use that duration, not the entire window.")
            ])
        } catch {
            return try json(["reliable": .bool(false), "reason": .string(error.localizedDescription),
                             "instruction": .string("Do not claim the user is free. Explain that availability cannot be verified.")])
        }
    }

    private func localTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func json(_ value: JSONObject) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
