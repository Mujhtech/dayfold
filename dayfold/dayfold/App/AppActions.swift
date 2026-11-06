import AppKit
import OSLog
import UniformTypeIdentifiers
import CalendarCore
import CalendarPlatform

extension AppModel {
    func connect(expected: CalendarAccount? = nil) {
        guard !isConnecting else { return }; isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                let identity = try await auth.authorize()
                if let expected, identity.subject != expected.subject { throw CalendarError.invalid("You chose a different Google account. Please reconnect \(expected.email).") }
                if isDemo { await loadStore(demo: false) }
                guard let repository else { return }
                let existing = try await repository.accounts().first { $0.subject == identity.subject }
                let account = CalendarAccount(id: existing?.id ?? AccountID(), subject: identity.subject, email: identity.email, scopes: identity.scopes)
                try await auth.store(identity, account: account.id)
                try await repository.connect(account, expected: expected?.id)
                for var m in try await repository.mutations() where m.key.calendar.account == account.id && m.state == .blockedAuthorization { m.state = .queued; try await repository.transition(m) }
                await sync?.refresh(window: visibleRange, forceMetadata: true)
                await reload()
                if existing == nil { showAccountSetup = true }
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func newDraft(start: Date? = nil, end: Date? = nil) {
        let start = start ?? Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970 / 900) * 900)
        let time = EventTime.timed(start: start, end: end ?? start.addingTimeInterval(Double(preferences.defaultDuration * 60)), startZone: preferences.timeZone.identifier, endZone: preferences.timeZone.identifier)
        let draft = EventDraft(calendar: preferences.defaultCalendar, fields: time.providerFields.merging(["summary": .string(""), "reminders": .object(["useDefault": .bool(true)])]) { _, v in v })
        Task { do { try await repository?.saveDraft(draft); editingDraft = draft } catch { errorMessage = error.localizedDescription } }
    }
    func quickPreview() {
        let preview = QuickEntryParser.parse(quickText, now: Date(), zone: preferences.timeZone, duration: preferences.defaultDuration, weekStart: calendar.firstWeekday)
        let nextSlot = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970 / 900) * 900)
        let time = preview.time ?? EventTime.timed(start: nextSlot, end: nextSlot.addingTimeInterval(Double(preferences.defaultDuration * 60)), startZone: preferences.timeZone.identifier, endZone: preferences.timeZone.identifier)
        var fields = time.providerFields; fields["summary"] = .string(preview.time == nil ? quickText : preview.title); if !preview.recurrence.isEmpty { fields["recurrence"] = .array(preview.recurrence.map(JSONValue.string)) }
        if preview.time == nil { fields["dayfoldParsingMessage"] = .string((preview.message ?? "The date could not be understood.") + " Choose the date and time below before saving.") }
        let draft = EventDraft(calendar: preferences.defaultCalendar, fields: fields)
        Task { do { try await repository?.saveDraft(draft); editingDraft = draft; quickText = ""; openCalendar?() } catch { errorMessage = error.localizedDescription } }
    }
    func edit(_ event: CalendarEvent, series: Bool = false) {
        Task {
            do {
                var source = event
                if series, let master = event.masterID {
                    let key = EventKey(calendar: event.key.calendar, eventID: master)
                    if let cached = try await repository?.event(key) { source = cached }
                    else if let provider { source = try await provider.event(key, zone: event.calendarZone) }
                    else { throw CalendarError.unavailable("Connect to load this series.") }
                }
                let capability = capability(.edit, event: source)
                guard capability.allowed else { throw CalendarError.permission(capability.reason) }
                let draft = EventDraft(calendar: source.key.calendar, source: source, fields: source.raw)
                try await repository?.saveDraft(draft); editingDraft = draft
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func duplicate(_ event: CalendarEvent) {
        var fields = event.time?.providerFields ?? [:]; fields["summary"] = .string(event.title); fields["location"] = .string(event.location); fields["description"] = .string(event.descriptionText)
        let draft = EventDraft(calendar: preferences.defaultCalendar, fields: fields)
        Task { do { try await repository?.saveDraft(draft); editingDraft = draft } catch { errorMessage = error.localizedDescription } }
    }
    func correct(_ mutation: Mutation) {
        Task { do { editingDraft = try await repository?.correctionDraft(for: mutation.id) } catch { errorMessage = error.localizedDescription } }
    }
    func submit(_ draft: EventDraft) async throws {
        guard let repository, let key = draft.calendar else { throw CalendarError.invalid("Choose a calendar for this event.") }
        guard let time = EventTime.decode(draft.fields, calendarZone: preferences.timeZone.identifier) else { throw CalendarError.invalid("Choose valid event dates.") }
        let allowed: Set<String> = ["summary", "description", "location", "start", "end", "recurrence", "attendees", "transparency", "visibility", "reminders", "conferenceData"]
        var fields = draft.fields.filter { allowed.contains($0.key) }
        if draft.source == nil, let attendees = fields["attendees"]?.array,
           attendees.contains(where: { $0["email"].string?.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) == nil }) {
            throw CalendarError.invalid("Each guest needs a valid, explicit email address.")
        }
        let eventKey: EventKey
        if let source = draft.source {
            guard source.key.calendar == key else { throw CalendarError.invalid("Use Duplicate to create a new personal event in a different calendar.") }
            eventKey = source.key; fields = fields.filter { source.raw[$0.key] != $0.value }
            if !source.recurrence.isEmpty && !Set(fields.keys).isDisjoint(with: ThreeWayMerge.structural) {
                guard RecurrenceRule.supportsStructuralEdit(source.recurrence) else { throw CalendarError.invalid("This custom recurrence cannot be changed safely here. The draft is preserved; open the series in Google Calendar for structural changes.") }
                if demoOffline || accounts.first(where: { $0.id == key.account })?.status != .healthy {
                    var review = draft; review.requiresOnlineReview = true; try await repository.saveDraft(review)
                    throw CalendarError.unavailable("The series change is saved as a draft. Review it online before sending.")
                }
                guard let provider else { throw CalendarError.missing }
                let remote = try await provider.event(source.key, zone: source.calendarZone)
                guard remote.etag == source.etag else { throw CalendarError.conflict }
            }
            if fields.isEmpty && draft.repairingMutationID == nil { try await repository.discardDraft(draft.id); editingDraft = nil; return }
        } else {
            eventKey = EventKey(calendar: key, eventID: draft.id.replacingOccurrences(of: "-", with: "").lowercased())
            fields["extendedProperties"] = .object(["private": .object(["dayfoldOperation": .string(draft.id)])])
        }
        if (draft.source == nil || !Set(fields.keys).isDisjoint(with: ThreeWayMerge.structural)), time.interval(in: preferences.timeZone).duration <= 0 { throw CalendarError.invalid("The end must be after the start.") }
        if (draft.source == nil || fields["summary"] != nil), fields.text("summary").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields["summary"] = .string("Untitled Event") }
        let mutation = Mutation(id: draft.id, key: eventKey, kind: draft.source == nil ? .create : .patch, fields: fields, base: draft.source)
        if let rejected = draft.repairingMutationID { try await repository.reviseRejected(rejected, fields: fields, draftID: draft.id) }
        else { try await repository.enqueue(mutation, draftID: draft.id) }
        logger.info("local_change_saved kind=\(mutation.kind.rawValue, privacy: .public)")
        queuedRedo = nil
        unsavedDrafts[draft.id] = nil
        editingDraft = nil; await reload()
        Task { await dispatcher?.drain(); await refresh() }
    }
    func removeEvent(_ event: CalendarEvent, series: Bool = false) {
        Task { do {
            var target = event
            if series, let master = event.masterID {
                let key = EventKey(calendar: event.key.calendar, eventID: master)
                if let cached = try await repository?.event(key) { target = cached }
                else if let provider { target = try await provider.event(key, zone: event.calendarZone) }
                else { throw CalendarError.unavailable("Connect to load the series before deleting it.") }
            }
            try await repository?.enqueue(Mutation(key: target.key, kind: .delete, fields: [:], base: target))
            selectedEvent = nil; await dispatcher?.drain(); await refresh()
        } catch { errorMessage = error.localizedDescription } }
    }
    func rsvp(_ event: CalendarEvent, response: String) {
        guard let attendee = event.selfAttendee else { return }
        let fields: JSONObject = ["attendeesOmitted": .bool(true), "attendees": .array([.object(["email": .string(attendee.text("email")), "responseStatus": .string(response)])])]
        Task { do { try await repository?.enqueue(Mutation(key: event.key, kind: .rsvp, fields: fields, base: event)); await dispatcher?.drain(); await refresh() } catch { errorMessage = error.localizedDescription } }
    }
    func rsvpSeries(_ event: CalendarEvent, response: String) {
        guard let master = event.masterID else { rsvp(event, response: response); return }
        Task { do {
            let key = EventKey(calendar: event.key.calendar, eventID: master)
            if let cached = try await repository?.event(key) { rsvp(cached, response: response) }
            else if let provider { rsvp(try await provider.event(key, zone: event.calendarZone), response: response) }
        } catch { errorMessage = "The series must be downloaded before a series response can be saved. " + error.localizedDescription } }
    }
    func openGoogle(_ event: CalendarEvent) {
        if let url = RichTextSafety.webURL(event.raw.text("htmlLink")), url.host == "calendar.google.com" || url.host == "www.google.com" { NSWorkspace.shared.open(url) }
        else if isDemo { errorMessage = "Demo events exist only on this Mac." }
        else { errorMessage = "Google did not provide a link for this event. Open Google Calendar and locate it in \(sourceLabel(event.key.calendar))." }
    }
    func route(to key: EventKey, join: Bool) {
        Task { do {
            if isDemo && !accounts.contains(where: { $0.id == key.calendar.account }) { await loadStore(demo: false) }
            guard let event = try await repository?.event(key) else { throw CalendarError.missing }
            selectedEvent = event; selectedDate = event.time?.interval(in: preferences.timeZone).start ?? selectedDate; page = .calendar
            openCalendar?(); dateChanged()
            if join {
                let links = RichTextSafety.meetingLinks(event)
                if links.count == 1 { NSWorkspace.shared.open(links[0]) }
                else { errorMessage = links.isEmpty ? "No valid meeting link is available." : "Choose the meeting destination in event details." }
            }
        } catch { errorMessage = error.localizedDescription; openCalendar?() } }
    }
    func exportRecovery(account: AccountID? = nil) async -> Bool {
        do {
            guard let data = try await repository?.recoveryExport(account: account) else { return false }
            let panel = NSSavePanel(); panel.nameFieldStringValue = "Dayfold-recovery.json"; panel.allowedContentTypes = [.json]; panel.message = "This file contains your calendar drafts and pending changes. Store it privately. It contains no Google credentials."
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            try data.write(to: url, options: .atomic); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func disconnect(_ account: CalendarAccount, export: Bool) {
        Task {
            if export { guard await exportRecovery(account: account.id) else { return } }
            do {
                var removing = account; removing.generation += 1; removing.status = .removing
                try await repository?.updateAccount(removing)
                if !isDemo { try await auth.remove(account.id) }
                await notifications?.removeAllForAccount(account.id)
                try await repository?.removeAccount(account.id, discardPending: true)
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func simulateOffline(_ value: Bool) { demoOffline = value; Task { await demoProvider?.setOffline(value); await refresh() } }
    func simulateConflict(_ event: CalendarEvent) {
        guard isDemo else { return }
        Task { do {
            try await repository?.enqueue(Mutation(key: event.key, kind: .patch, fields: ["summary": .string(event.title + " · my edit")], base: event))
            try await demoProvider?.remoteEdit(event.key, fields: ["summary": .string(event.title + " · remote edit")]); await dispatcher?.drain(); page = .pending
        } catch { errorMessage = error.localizedDescription } }
    }
}
