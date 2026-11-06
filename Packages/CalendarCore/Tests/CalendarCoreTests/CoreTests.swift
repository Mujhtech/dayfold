import Foundation
import Testing
@testable import CalendarCore

private let fixtureDate = InternetDate.parse("2026-11-05T12:00:00Z")!
private let fixtureWindow = DateInterval(start: InternetDate.parse("2026-10-01T00:00:00Z")!, end: InternetDate.parse("2026-12-01T00:00:00Z")!)

struct Harness {
    var repo: CalendarRepository
    var provider: DemoProvider
    var sync: SyncCoordinator
    var dispatcher: MutationDispatcher
    var data: DemoDataset
    var path: String
    static func make(events: Int = 30, pageSize: Int = 4) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("test.sqlite").path
        let repo = try CalendarRepository(path: path)
        let data = FixtureFactory.demo(now: fixtureDate, accountCount: 2, calendarsPerAccount: 2, eventCount: events)
        for account in data.accounts { try await repo.connect(account) }
        let provider = try DemoProvider(dataset: data, pageSize: pageSize), gate = CalendarWorkGate()
        let sync = SyncCoordinator(repository: repo, provider: provider, gate: gate)
        await sync.refresh(window: fixtureWindow)
        return Self(repo: repo, provider: provider, sync: sync, dispatcher: MutationDispatcher(repository: repo, provider: provider, gate: gate), data: data, path: path)
    }
    func create(title: String = "Saved offline") -> Mutation {
        let key = EventKey(calendar: data.calendars[0].key, eventID: UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))
        var mutation = Mutation(key: key, kind: .create, fields: ["summary": .string(title)], base: nil, created: fixtureDate)
        mutation.fields.merge(EventTime.timed(start: fixtureDate, end: fixtureDate.addingTimeInterval(1800), startZone: "Africa/Lagos", endZone: "Africa/Lagos").providerFields) { _, v in v }
        mutation.fields["extendedProperties"] = .object(["private": .object(["dayfoldOperation": .string(mutation.id)])])
        return mutation
    }
}

@Test func civilDatesAndDST() throws {
    let zone = TimeZone(identifier: "Europe/London")!
    #expect(WallTime.candidates(day: try LocalDate("2026-03-29"), hour: 1, minute: 30, zone: zone).isEmpty)
    let repeated = WallTime.candidates(day: try LocalDate("2026-10-25"), hour: 1, minute: 30, zone: zone)
    #expect(repeated.count == 2)
    #expect(repeated.last!.timeIntervalSince(repeated.first!) == 3600)
    let time = EventTime.allDay(start: try LocalDate("2026-03-28"), end: try LocalDate("2026-03-30"))
    #expect(time.interval(in: zone).duration == 47 * 3600)
    #expect(try LocalDate("2024-02-28").adding(days: 1) == LocalDate("2024-02-29"))
    #expect(throws: (any Error).self) { try LocalDate("2026-02-29") }
}
@Test func nonHourOffsetsAndHalfHourTransition() throws {
    let ktm = TimeZone(identifier: "Asia/Kathmandu")!, lord = TimeZone(identifier: "Australia/Lord_Howe")!
    #expect(ktm.secondsFromGMT(for: fixtureDate) == 20700)
    #expect(WallTime.candidates(day: try LocalDate("2026-10-04"), hour: 2, minute: 15, zone: lord).isEmpty)
    #expect(WallTime.candidates(day: try LocalDate("2026-04-05"), hour: 1, minute: 45, zone: lord).count == 2)
}
@Test func identityScopesOpaqueIDs() {
    let a = AccountID(rawValue: "a"), b = AccountID(rawValue: "b")
    let first = CalendarKey(account: a, calendarID: "primary@example.com"), second = CalendarKey(account: b, calendarID: "primary@example.com")
    #expect(first != second)
    #expect(EventKey(calendar: first, eventID: "same") != EventKey(calendar: second, eventID: "same"))
    let url = GoogleCalendarProvider.url(path: ["calendars", "a/b+#?@example.com", "events", "event/id"])
    #expect(url.absoluteString.contains("a%2Fb%2B%23%3F%40example.com"))
    #expect(url.absoluteString.contains("event%2Fid"))
}
@Test func endExclusiveOverlapAndColumns() throws {
    let d = FixtureFactory.demo(now: fixtureDate, accountCount: 1, calendarsPerAccount: 1, eventCount: 3)
    var events = d.events
    for i in events.indices {
        let start = fixtureDate.addingTimeInterval(Double(i) * 3600)
        events[i].raw.merge(EventTime.timed(start: start, end: start.addingTimeInterval(3600), startZone: "UTC", endZone: "UTC").providerFields) { _, v in v }
    }
    let day = DateInterval(start: fixtureDate.addingTimeInterval(-3600), duration: 86400)
    #expect(TimelineLayout.place(events, day: day, zone: .gmt).allSatisfy { $0.columns == 1 })
    events[1].raw["start"] = events[0].raw["start"]
    let placed = TimelineLayout.place(events, day: day, zone: .gmt)
    #expect(placed.filter { $0.columns == 2 }.count == 2)
}
@Test func durableOfflineCreateAndDraftRestart() async throws {
    let h = try await Harness.make()
    let draft = EventDraft(calendar: h.data.calendars[0].key, fields: ["summary": .string("Unsent text")])
    try await h.repo.saveDraft(draft)
    let m = h.create(); try await h.repo.enqueue(m)
    await h.provider.setOffline(true); await h.dispatcher.drain(now: fixtureDate)
    let restarted = try CalendarRepository(path: h.path)
    let snapshot = try await restarted.snapshot(interval: fixtureWindow, displayZone: .gmt)
    #expect(snapshot.drafts.contains { $0.id == draft.id })
    #expect(snapshot.events.contains { $0.key == m.key && $0.title == "Saved offline" && $0.localState != nil })
    await h.provider.setOffline(false)
    let dispatcher = MutationDispatcher(repository: restarted, provider: h.provider, gate: CalendarWorkGate())
    await dispatcher.drain(now: fixtureDate.addingTimeInterval(4000))
    #expect(try await restarted.mutations().first { $0.id == m.id }?.state == .confirmed)
}
@Test func lostInsertResponseNeverDuplicates() async throws {
    let h = try await Harness.make()
    let m = h.create(); try await h.repo.enqueue(m)
    await h.provider.loseNextWriteResponse(); await h.dispatcher.drain(now: fixtureDate)
    #expect(try await h.repo.mutations().first { $0.id == m.id }?.state == .uncertain)
    let restarted = try CalendarRepository(path: h.path)
    await MutationDispatcher(repository: restarted, provider: h.provider, gate: CalendarWorkGate()).drain(now: fixtureDate.addingTimeInterval(4000))
    #expect(await h.provider.writeCount == 1)
    #expect(try await restarted.mutations().first { $0.id == m.id }?.state == .confirmed)
}
@Test func repeatedSaveAndCoalescing() async throws {
    let h = try await Harness.make()
    let m = h.create(); try await h.repo.enqueue(m); try await h.repo.enqueue(m)
    var base = CalendarEvent(key: m.key, raw: m.fields); base.raw["id"] = .string(m.key.eventID)
    let edit = Mutation(key: m.key, kind: .patch, fields: ["summary": .string("Final title")], base: base)
    try await h.repo.enqueue(edit)
    #expect(try await h.repo.mutations().filter { $0.state.pending }.count == 1)
    await h.dispatcher.drain(now: fixtureDate)
    #expect(try await h.provider.event(m.key, zone: "UTC").title == "Final title")
    #expect(await h.provider.writeCount == 1)
}
@Test func createThenDeleteHasNoRemoteWrite() async throws {
    let h = try await Harness.make(); let m = h.create(); try await h.repo.enqueue(m)
    let base = CalendarEvent(key: m.key, raw: m.fields)
    try await h.repo.enqueue(Mutation(key: m.key, kind: .delete, fields: [:], base: base))
    await h.dispatcher.drain(now: fixtureDate)
    #expect(await h.provider.writeCount == 0)
}
@Test func scalarMergePreservesUnknownMetadata() async throws {
    let h = try await Harness.make(); let event = h.data.events.first { $0.key.calendar == h.data.calendars[0].key && $0.selfAttendee == nil }!
    let m = Mutation(key: event.key, kind: .patch, fields: ["summary": .string("Local title")], base: event)
    try await h.repo.enqueue(m)
    try await h.provider.remoteEdit(event.key, fields: ["location": .string("Remote room"), "futureField": .object(["keep": .bool(true)])])
    await h.dispatcher.drain()
    let remote = try await h.provider.event(event.key, zone: "UTC")
    #expect(remote.title == "Local title"); #expect(remote.location == "Remote room"); #expect(remote.raw["futureField"]?["keep"].bool == true)
}
@Test func sameFieldConflictSurvivesRebuild() async throws {
    let h = try await Harness.make(); let event = h.data.events.first { $0.key.calendar == h.data.calendars[0].key && $0.selfAttendee == nil }!
    try await h.repo.enqueue(Mutation(key: event.key, kind: .patch, fields: ["summary": .string("Local")], base: event))
    try await h.provider.remoteEdit(event.key, fields: ["summary": .string("Remote")]); await h.dispatcher.drain()
    try await h.repo.rebuildRemoteCache()
    let state = try await h.repo.snapshot(interval: fixtureWindow, displayZone: .gmt)
    #expect(state.conflicts.count == 1); #expect(state.conflicts[0].fields == ["summary"])
    #expect(state.events.contains { $0.key == event.key && $0.title == "Local" })
    try await h.repo.resolveConflict(state.conflicts[0].id, applyLocal: true); await h.dispatcher.drain()
    #expect(try await h.provider.event(event.key, zone: "UTC").title == "Local")
}
@Test func paginationAndQueryIsolation() async throws {
    let h = try await Harness.make(events: 60, pageSize: 2)
    let snapshot = try await h.repo.snapshot(interval: fixtureWindow, displayZone: .gmt)
    #expect(snapshot.events.count == 60)
    #expect(snapshot.calendars.count == 4)
    #expect(try await h.repo.cursor(h.data.calendars[0].key, fingerprint: EventQuery.fingerprint) != nil)
    let parameters = EventQuery.resources(syncToken: "cursor").parameters
    #expect(parameters["timeMin"] == nil && parameters["orderBy"] == nil && parameters["q"] == nil)
    #expect(EventQuery.occurrences(fixtureWindow).parameters["syncToken"] == nil)
}
@Test func incompleteSnapshotAndGenerationCannotReplaceCache() async throws {
    let h = try await Harness.make(); let c = try await h.repo.calendar(h.data.calendars[0].key)!
    let initial = try await h.repo.snapshot(interval: fixtureWindow, displayZone: .gmt).events.count
    try await h.repo.stage([], run: "partial", source: c)
    #expect(try await h.repo.snapshot(interval: fixtureWindow, displayZone: .gmt).events.count == initial)
    try await h.repo.enqueue(h.create())
    await #expect(throws: CalendarError.staleGeneration) { try await h.repo.publish(run: "partial", source: c, window: fixtureWindow) }
    try await h.repo.removeAccount(c.key.account, discardPending: true)
    await #expect(throws: CalendarError.staleGeneration) { try await h.repo.stage(h.data.events.filter { $0.key.calendar == c.key }, run: "late", source: c) }
}
@Test func reconnectionDeduplicatesSubjectAndRejectsWrongAccount() async throws {
    let h = try await Harness.make(); var changed = h.data.accounts[0]; changed.id = AccountID(); changed.email = "renamed@example.com"
    let result = try await h.repo.connect(changed)
    #expect(result.id == h.data.accounts[0].id)
    await #expect(throws: (any Error).self) { try await h.repo.connect(h.data.accounts[1], expected: h.data.accounts[0].id) }
    #expect(try await h.repo.accounts().count == 2)
}
@Test func permissionsAcrossSourcesAndRedaction() async throws {
    let h = try await Harness.make(); let source = h.data.calendars[1], event = h.data.events.first { $0.key.calendar == source.key }!
    let denied = EventCapabilityResolver.resolve(.edit, account: h.data.accounts[0], calendar: source, event: event)
    #expect(!denied.allowed)
    #expect(!EventCapabilityResolver.resolve(.edit, account: h.data.accounts[1], calendar: source, event: event).allowed)
    var sources = h.data.calendars.filter { $0.key.account == h.data.accounts[0].id }; sources[0].role = "freeBusyReader"
    try await h.repo.reconcileCalendars(sources, account: h.data.accounts[0].id, generation: 0)
    let result = try await h.repo.snapshot(interval: fixtureWindow, displayZone: .gmt)
    #expect(!result.events.contains { $0.key.calendar == sources[0].key })
}
@Test func pendingRecoveryExportAndDisconnectChoice() async throws {
    let h = try await Harness.make(); try await h.repo.enqueue(h.create())
    await #expect(throws: (any Error).self) { try await h.repo.removeAccount(h.data.accounts[0].id, discardPending: false) }
    let data = try await h.repo.recoveryExport()
    let json = try JSONDecoder().decode(JSONObject.self, from: data)
    #expect(json.text("format") == "dayfold-recovery")
    #expect(json["pendingChanges"]?.array?.count == 1)
    #expect(!String(decoding: data, as: UTF8.self).contains("access_token"))
}
@Test func rsvpPreservesOtherAttendees() async throws {
    let h = try await Harness.make(); let e = h.data.events[0]
    let fields: JSONObject = ["attendeesOmitted": .bool(true), "attendees": .array([.object(["email": .string(e.selfAttendee!.text("email")), "responseStatus": .string("accepted")])])]
    try await h.repo.enqueue(Mutation(key: e.key, kind: .rsvp, fields: fields, base: e)); await h.dispatcher.drain()
    let result = try await h.provider.event(e.key, zone: "UTC")
    #expect(result.attendees.count == e.attendees.count); #expect(result.response == "accepted")
}
@Test(arguments: ["javascript:alert(1)", "file:///etc/passwd", "data:text/html,hello", "https://user:password@example.com"]) func unsafeLinks(value: String) { #expect(RichTextSafety.webURL(value) == nil) }
@Test func richTextNeverLoadsOrExecutesContent() {
    #expect(RichTextSafety.plainText("<script>bad()</script><img src='https://tracker.example'><b>Hello</b>") == "Hello")
}
@Test func quickEntryAmbiguityAndValidPreview() {
    let zone = TimeZone(identifier: "Africa/Lagos")!
    let valid = QuickEntryParser.parse("Client review tomorrow at 14:00", now: fixtureDate, zone: zone)
    #expect(valid.title == "Client review"); #expect(valid.time != nil)
    #expect(QuickEntryParser.parse("Review 03/04 at 2", now: fixtureDate, zone: zone).time == nil)
    #expect(QuickEntryParser.parse("Meeting tomorrow at 25:00", now: fixtureDate, zone: zone).time == nil)
    #expect(QuickEntryParser.parse("Standup every Monday at 09:00", now: fixtureDate, zone: zone).recurrence.first?.contains("BYDAY=MO") == true)
}
@Test func recurrencePreservesSemantics() throws {
    var rule = RecurrenceRule(frequency: .monthly); rule.monthDay = 31; rule.count = 5
    #expect(try rule.line(allDay: false) == "RRULE:FREQ=MONTHLY;INTERVAL=1;BYMONTHDAY=31;COUNT=5")
    rule.until = try LocalDate("2026-12-31"); #expect(throws: (any Error).self) { try rule.line(allDay: false) }
}
@Test func reminderIdentityPrivacyAndCancellation() {
    var d = FixtureFactory.demo(now: fixtureDate, accountCount: 1, calendarsPerAccount: 1, eventCount: 1)
    d.events[0].raw.merge(EventTime.timed(start: fixtureDate.addingTimeInterval(3600), end: fixtureDate.addingTimeInterval(7200), startZone: "UTC", endZone: "UTC").providerFields) { _, v in v }
    var p = Preferences(); p.notifications = true; p.privateNotifications = true
    let plan = ReminderPlanner.plan(events: d.events, calendars: d.calendars, preferences: p, now: fixtureDate)
    #expect(plan.count == 1); #expect(plan[0].title == "Busy event")
    #expect(plan == ReminderPlanner.plan(events: d.events, calendars: d.calendars, preferences: p, now: fixtureDate))
    d.events[0].raw["status"] = .string("cancelled")
    #expect(ReminderPlanner.plan(events: d.events, calendars: d.calendars, preferences: p, now: fixtureDate).isEmpty)
}
@Test func reasonAwareFailures() {
    #expect(ProviderError.classify(status: 403, reason: "forbidden", retryAfter: nil) == .forbidden)
    #expect(ProviderError.classify(status: 403, reason: "rateLimitExceeded", retryAfter: "120") == .throttled(120))
    #expect(ProviderError.classify(status: 410, reason: "", retryAfter: nil) == .expiredCursor)
    #expect(ProviderError.classify(status: 412, reason: "", retryAfter: nil) == .conflict)
}
