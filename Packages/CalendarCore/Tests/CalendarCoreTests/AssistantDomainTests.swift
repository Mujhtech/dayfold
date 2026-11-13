import Foundation
import Testing
@testable import CalendarCore

private func assistantSource(_ id: String = "primary", visible: Bool = true, enabled: Bool = true) -> CalendarSource {
    CalendarSource(key: CalendarKey(account: AccountID(rawValue: "assistant-tests"), calendarID: id), title: id, role: "owner", syncEnabled: enabled, visible: visible)
}

private func assistantWindow(_ day: LocalDate, zone: TimeZone = .gmt) -> DateInterval {
    DateInterval(start: day.start(in: zone), end: day.adding(days: 1).start(in: zone))
}

private func assistantCoverage(_ source: CalendarSource, window: DateInterval, stale: Bool = false) -> CacheCoverage {
    CacheCoverage(id: UUID().uuidString, calendar: source.key, interval: window, fetched: window.start, generation: source.generation, writeEpoch: source.writeEpoch, stale: stale)
}

private func assistantEvent(_ id: String, source: CalendarSource, start: String, end: String, fields: JSONObject = [:]) -> CalendarEvent {
    var raw = EventTime.timed(start: InternetDate.parse(start)!, end: InternetDate.parse(end)!, startZone: "UTC", endZone: "UTC").providerFields
    raw["summary"] = .string(id)
    raw.merge(fields) { _, value in value }
    return CalendarEvent(key: EventKey(calendar: source.key, eventID: id), raw: raw)
}

private func assistantSnapshot(sources: [CalendarSource], events: [CalendarEvent] = [], coverage: [CacheCoverage]) -> RepositorySnapshot {
    RepositorySnapshot(accounts: [], calendars: sources, events: events, mutations: [], drafts: [], conflicts: [], coverage: coverage, recentChanges: [])
}

@Test func assistantContextUsesSynchronizedCalendarsIncludingHiddenSources() throws {
    let day = try LocalDate("2026-11-07"), source = assistantSource(), hidden = assistantSource("hidden", visible: false), disabled = assistantSource("disabled", enabled: false)
    var deleted = assistantSource("deleted"); deleted.deleted = true
    let window = assistantWindow(day)
    let events = [source, hidden, disabled, deleted].map {
        assistantEvent($0.title, source: $0, start: "2026-11-07T10:00:00Z", end: "2026-11-07T11:00:00Z", fields: ["description": .string("Private event body"), "attendees": .array([.object(["email": .string("guest@example.com")])]), "hangoutLink": .string("https://meet.example.com/private")])
    }
    let context = try AssistantDayContext(snapshot: assistantSnapshot(sources: [source, hidden, disabled, deleted], events: events, coverage: [source, hidden].map { assistantCoverage($0, window: window) }), day: day, timeZone: .gmt)
    #expect(Set(context.calendars.map(\.key)) == Set([source.key, hidden.key]))
    #expect(Set(context.events.map(\.title)) == Set([source.title, hidden.title]))
    #expect(context.excludedCalendarCount == 1)
    #expect(context.availabilityIsReliable)
}

@Test func assistantAvailabilityFailsClosedForCacheGapsAndStaleEpochs() throws {
    let day = try LocalDate("2026-11-07"), source = assistantSource(), second = assistantSource("second"), window = assistantWindow(day)
    let midpoint = window.start.addingTimeInterval(12 * 3600)
    let firstHalf = assistantCoverage(source, window: DateInterval(start: window.start, end: midpoint))
    let secondHalf = assistantCoverage(source, window: DateInterval(start: midpoint, end: window.end))
    let joined = try AssistantDayContext(snapshot: assistantSnapshot(sources: [source], coverage: [firstHalf, secondHalf]), day: day, timeZone: .gmt)
    #expect(joined.availabilityIsReliable)

    var stale = secondHalf; stale.stale = true
    var wrongEpoch = secondHalf; wrongEpoch.writeEpoch += 1
    var wrongGeneration = secondHalf; wrongGeneration.generation += 1
    let missing = try AssistantDayContext(snapshot: assistantSnapshot(sources: [source, second], coverage: [firstHalf, secondHalf]), day: day, timeZone: .gmt)
    #expect(!missing.calendars.first(where: { $0.key == second.key })!.isComplete)
    for context in [missing] + (try [[firstHalf], [firstHalf, stale], [firstHalf, wrongEpoch], [firstHalf, wrongGeneration]].map {
        try AssistantDayContext(snapshot: assistantSnapshot(sources: [source], coverage: $0), day: day, timeZone: .gmt)
    }) {
        #expect(!context.availabilityIsReliable)
        #expect(throws: CalendarError.self) { try AssistantAvailability.freeSlots(in: context, durationMinutes: 30, workStart: 9, workEnd: 17) }
    }
    let empty = try AssistantDayContext(snapshot: assistantSnapshot(sources: [], coverage: []), day: day, timeZone: .gmt)
    #expect(throws: CalendarError.self) { try AssistantAvailability.freeSlots(in: empty, durationMinutes: 30, workStart: 9, workEnd: 17) }
}

@Test func assistantFreeTimeMergesOverlapsAndIgnoresTransparentDeclinedEvents() throws {
    let day = try LocalDate("2026-11-07"), source = assistantSource(), window = assistantWindow(day)
    let events = [
        assistantEvent("first", source: source, start: "2026-11-07T09:30:00Z", end: "2026-11-07T11:00:00Z"),
        assistantEvent("overlap", source: source, start: "2026-11-07T10:00:00Z", end: "2026-11-07T12:00:00Z"),
        assistantEvent("adjacent", source: source, start: "2026-11-07T12:00:00Z", end: "2026-11-07T13:00:00Z"),
        assistantEvent("transparent", source: source, start: "2026-11-07T13:00:00Z", end: "2026-11-07T14:00:00Z", fields: ["transparency": .string("transparent")]),
        assistantEvent("declined", source: source, start: "2026-11-07T14:00:00Z", end: "2026-11-07T15:00:00Z", fields: ["attendees": .array([.object(["self": .bool(true), "responseStatus": .string("declined")])])]),
        assistantEvent("outside", source: source, start: "2026-11-08T09:00:00Z", end: "2026-11-08T18:00:00Z")
    ]
    let context = try AssistantDayContext(snapshot: assistantSnapshot(sources: [source], events: events, coverage: [assistantCoverage(source, window: window)]), day: day, timeZone: .gmt)
    let slots = try AssistantAvailability.freeSlots(in: context, durationMinutes: 30, workStart: 9, workEnd: 17)
    #expect(slots == [DateInterval(start: InternetDate.parse("2026-11-07T09:00:00Z")!, duration: 1800), DateInterval(start: InternetDate.parse("2026-11-07T13:00:00Z")!, duration: 4 * 3600)])
    let remaining = try AssistantAvailability.freeSlots(in: context, durationMinutes: 30, workStart: 9, workEnd: 17, notBefore: InternetDate.parse("2026-11-07T16:45:00Z")!)
    #expect(remaining.isEmpty)
}

@Test func assistantAllDayBusyAndRestrictedEventsStayPrivate() throws {
    let day = try LocalDate("2026-11-07"), source = assistantSource(), window = assistantWindow(day)
    var raw = EventTime.allDay(start: day.adding(days: -1), end: day.adding(days: 1)).providerFields
    raw["summary"] = .string("Private all-day plan")
    raw["visibility"] = .string("private")
    var restricted = source; restricted.role = "writerWithoutPrivateAccess"
    let event = CalendarEvent(key: EventKey(calendar: source.key, eventID: "all-day"), raw: raw)
    let context = try AssistantDayContext(snapshot: assistantSnapshot(sources: [restricted], events: [event], coverage: [assistantCoverage(restricted, window: window)]), day: day, timeZone: .gmt)
    #expect(context.events.first?.title == "Busy")
    #expect(context.events.first?.isAllDay == true)
    #expect(try AssistantAvailability.freeSlots(in: context, durationMinutes: 30, workStart: 9, workEnd: 17).isEmpty)
}

@Test func assistantTruncatedAndInvalidContextCannotClaimFreeTime() throws {
    let day = try LocalDate("2026-11-07"), source = assistantSource(), window = assistantWindow(day)
    let events = (0..<2).map { assistantEvent("event-\($0)", source: source, start: "2026-11-07T09:00:00Z", end: "2026-11-07T10:00:00Z") }
    let truncated = try AssistantDayContext(snapshot: assistantSnapshot(sources: [source], events: events, coverage: [assistantCoverage(source, window: window)]), day: day, timeZone: .gmt, maximumEvents: 1)
    #expect(truncated.events.count == 1 && truncated.totalEventCount == 2 && truncated.eventsTruncated)
    #expect(throws: CalendarError.self) { try AssistantAvailability.freeSlots(in: truncated, durationMinutes: 30, workStart: 9, workEnd: 17) }
    let invalidEvent = CalendarEvent(key: EventKey(calendar: source.key, eventID: "bad-time"), raw: ["summary": .string("Unknown time")])
    let invalid = try AssistantDayContext(snapshot: assistantSnapshot(sources: [source], events: [invalidEvent], coverage: [assistantCoverage(source, window: window)]), day: day, timeZone: .gmt)
    #expect(invalid.invalidEventCount == 1)
    #expect(!invalid.availabilityIsReliable)
}

@Test func assistantAvailabilityUsesCivilDayAcrossDSTAndValidatesWorkHours() throws {
    let zone = TimeZone(identifier: "Europe/London")!, source = assistantSource()
    for (date, hours) in [("2026-03-29", 23), ("2026-10-25", 25)] {
        let day = try LocalDate(date), window = assistantWindow(day, zone: zone)
        let context = try AssistantDayContext(snapshot: assistantSnapshot(sources: [source], coverage: [assistantCoverage(source, window: window)]), day: day, timeZone: zone)
        let slots = try AssistantAvailability.freeSlots(in: context, durationMinutes: 30, workStart: 0, workEnd: 24)
        #expect(slots.count == 1 && slots[0].duration == Double(hours * 3600))
        for (start, end) in [(-1, 17), (9, 25), (18, 9), (9, 9)] {
            #expect(throws: CalendarError.self) { try AssistantAvailability.freeSlots(in: context, durationMinutes: 30, workStart: start, workEnd: end) }
        }
        for duration in [14, 241] {
            #expect(throws: CalendarError.self) { try AssistantAvailability.freeSlots(in: context, durationMinutes: duration, workStart: 0, workEnd: 24) }
        }
    }
}

@Test func assistantProposalRequiresExactValidDateTimeAndDuration() throws {
    let zone = TimeZone(identifier: "Europe/London")!
    let invalid = [
        AssistantEventProposal(title: "Lunch", date: "2026-02-30", time: "13:00", durationMinutes: 30),
        AssistantEventProposal(title: "Lunch", date: "2026-2-03", time: "13:00", durationMinutes: 30),
        AssistantEventProposal(title: "Lunch", date: "tomorrow", time: "13:00", durationMinutes: 30),
        AssistantEventProposal(title: "Lunch", date: "2026-11-07", time: "1pm", durationMinutes: 30),
        AssistantEventProposal(title: "Lunch", date: "2026-11-07", time: "24:00", durationMinutes: 30),
        AssistantEventProposal(title: "Lunch", date: "2026-11-07", time: "13:60", durationMinutes: 30),
        AssistantEventProposal(title: "Lunch", date: "2026-03-29", time: "01:30", durationMinutes: 30),
        AssistantEventProposal(title: "Lunch", date: "2026-10-25", time: "01:30", durationMinutes: 30),
        AssistantEventProposal(title: "Lunch", date: "2026-11-07", time: "13:00", durationMinutes: 14),
        AssistantEventProposal(title: "Lunch", date: "2026-11-07", time: "13:00", durationMinutes: 241),
        AssistantEventProposal(title: "   ", date: "2026-11-07", time: "13:00", durationMinutes: 30),
        AssistantEventProposal(title: String(repeating: "x", count: 201), date: "2026-11-07", time: "13:00", durationMinutes: 30)
    ]
    for proposal in invalid { #expect(throws: CalendarError.self) { try proposal.validatedTime(in: zone) } }
}

@Test func assistantProposalMakesOnlyAnExplicitNewEventDraft() throws {
    let source = assistantSource(), zone = TimeZone(identifier: "Africa/Lagos")!
    for duration in [15, 240] {
        let proposal = AssistantEventProposal(title: "  Lunch  ", date: "2026-11-07", time: "13:00", durationMinutes: duration)
        let restored = try JSONDecoder().decode(AssistantEventProposal.self, from: JSONEncoder().encode(proposal))
        #expect(restored == proposal)
        let draft = try proposal.draft(calendar: source.key, timeZone: zone)
        #expect(draft.calendar == source.key && draft.source == nil)
        #expect(draft.fields.text("summary") == "Lunch")
        #expect(Set(draft.fields.keys) == Set(["summary", "start", "end", "reminders"]))
        let time = try #require(EventTime.decode(draft.fields, calendarZone: zone.identifier))
        #expect(time.interval(in: zone).start == InternetDate.parse("2026-11-07T12:00:00Z"))
        #expect(time.interval(in: zone).duration == Double(duration * 60))
    }
}
