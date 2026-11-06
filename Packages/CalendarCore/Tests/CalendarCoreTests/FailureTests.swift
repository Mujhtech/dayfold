import Foundation
import Testing
import Darwin
@testable import CalendarCore

private actor PagingProvider: CalendarProvider {
    let base: DemoProvider
    var failPage: String?
    var emptyFirst = false
    var expired = false
    var queries: [EventQuery] = []
    init(base: DemoProvider) { self.base = base }
    func configure(failPage: String? = nil, emptyFirst: Bool = false, expired: Bool = false) { self.failPage = failPage; self.emptyFirst = emptyFirst; self.expired = expired }
    func calendars(account: AccountID, page: String?) async throws -> ProviderPage<CalendarSource> { try await base.calendars(account: account, page: page) }
    func events(source: CalendarSource, query: EventQuery, page: String?) async throws -> ProviderPage<CalendarEvent> {
        queries.append(query)
        if case .resources(let token) = query, token != nil, expired { expired = false; throw ProviderError.expiredCursor }
        if page == failPage && page != nil { throw ProviderError.network }
        if emptyFirst && page == nil { return ProviderPage(items: [], nextPage: "empty-continued") }
        return try await base.events(source: source, query: query, page: page == "empty-continued" ? nil : page)
    }
    func event(_ key: EventKey, zone: String) async throws -> CalendarEvent { try await base.event(key, zone: zone) }
    func write(_ mutation: Mutation, etag: String?, zone: String) async throws -> CalendarEvent? { try await base.write(mutation, etag: etag, zone: zone) }
    func busy(source: CalendarSource, window: DateInterval) async throws -> [CalendarEvent] { try await base.busy(source: source, window: window) }
}
private let range = DateInterval(start: InternetDate.parse("2026-10-01T00:00:00Z")!, end: InternetDate.parse("2026-12-01T00:00:00Z")!)

@Test func emptyPagesMustFollowNextPage() async throws {
    let h = try await Harness.make(events: 40, pageSize: 2)
    let p = PagingProvider(base: h.provider); await p.configure(emptyFirst: true)
    let sync = SyncCoordinator(repository: h.repo, provider: p, gate: CalendarWorkGate())
    try await sync.refreshCalendar(try await h.repo.calendar(h.data.calendars[0].key)!, window: range)
    let result = try await h.repo.snapshot(interval: range, displayZone: .gmt)
    #expect(result.events.count == 40)
    #expect(await p.queries.count > 4)
}
@Test func failedSecondPagePreservesOldWindowAndCursor() async throws {
    let h = try await Harness.make(events: 40, pageSize: 2)
    let source = try await h.repo.calendar(h.data.calendars[0].key)!
    let token = try await h.repo.cursor(source.key, fingerprint: EventQuery.fingerprint)
    let p = PagingProvider(base: h.provider); await p.configure(failPage: "2")
    let sync = SyncCoordinator(repository: h.repo, provider: p, gate: CalendarWorkGate())
    await #expect(throws: ProviderError.network) { try await sync.refreshCalendar(source, window: range) }
    #expect(try await h.repo.snapshot(interval: range, displayZone: .gmt).events.count == 40)
    #expect(try await h.repo.cursor(source.key, fingerprint: EventQuery.fingerprint) == token)
}
@Test func expiredCursorResetsOnlyRemoteCollection() async throws {
    let h = try await Harness.make(events: 40, pageSize: 2)
    try await h.repo.enqueue(h.create())
    let source = try await h.repo.calendar(h.data.calendars[0].key)!
    let p = PagingProvider(base: h.provider); await p.configure(expired: true)
    try await SyncCoordinator(repository: h.repo, provider: p, gate: CalendarWorkGate()).refreshCalendar(source, window: range)
    #expect(try await h.repo.mutations().count == 1)
    #expect(await p.queries.contains(.resources(syncToken: nil)))
    #expect(try await h.repo.accounts().count == 2)
}
@Test func resourceReplayAndMinimalCancellation() async throws {
    let h = try await Harness.make(events: 30)
    let source = try await h.repo.calendar(h.data.calendars[0].key)!
    let target = h.data.events.first { $0.key.calendar == source.key }!
    let tombstone = CalendarEvent(key: target.key, raw: ["id": .string(target.key.eventID), "status": .string("cancelled")])
    for pass in 0..<2 {
        try await h.repo.stage([tombstone], run: "pass\(pass)", source: source)
        try await h.repo.publish(run: "pass\(pass)", source: source, token: "next", fingerprint: EventQuery.fingerprint)
    }
    #expect(try await h.repo.snapshot(interval: range, displayZone: .gmt).events.contains { $0.key == target.key } == false)
}
@Test func executingOperationsBecomeUncertainAfterCrash() async throws {
    let h = try await Harness.make(); var mutation = h.create(); try await h.repo.enqueue(mutation)
    mutation.state = .executing; mutation.attempts = 1; try await h.repo.transition(mutation)
    let reopened = try CalendarRepository(path: h.path)
    #expect(try await reopened.mutations().first?.state == .uncertain)
}
@Test func lostRSVPResponseDoesNotSendTwice() async throws {
    let h = try await Harness.make(); let e = h.data.events[0]
    let fields: JSONObject = ["attendeesOmitted": .bool(true), "attendees": .array([.object(["email": .string(e.selfAttendee!.text("email")), "responseStatus": .string("tentative")])])]
    try await h.repo.enqueue(Mutation(key: e.key, kind: .rsvp, fields: fields, base: e))
    await h.provider.loseNextWriteResponse(); await h.dispatcher.drain()
    await h.dispatcher.drain(now: Date().addingTimeInterval(4000))
    #expect(await h.provider.writeCount == 1)
    #expect(try await h.repo.mutations().last?.state == .confirmed)
}
@Test func invalidGuestArrayAndSpecializedEventsAreConservative() async throws {
    let h = try await Harness.make()
    var e = h.data.events.first { $0.key.calendar == h.data.calendars[0].key && $0.selfAttendee == nil }!
    for kind in ["outOfOffice", "focusTime", "workingLocation", "birthday", "fromGmail", "futureType"] {
        e.raw["eventType"] = .string(kind)
        #expect(!EventCapabilityResolver.resolve(.edit, account: h.data.accounts[0], calendar: h.data.calendars[0], event: e).allowed)
    }
    let json = "{\"id\":\"abc\",\"future\":{\"nullable\":null,\"array\":[true,3,\"text\"]}}".data(using: .utf8)!
    let raw = try JSONDecoder().decode(JSONObject.self, from: json)
    #expect(try JSONDecoder().decode(JSONObject.self, from: JSONEncoder().encode(raw)) == raw)
}
@Test func accountFailureDoesNotBlockHealthyAccount() async throws {
    let h = try await Harness.make()
    await h.provider.failNext(.unauthorized)
    await SyncCoordinator(repository: h.repo, provider: h.provider, gate: CalendarWorkGate()).refresh(window: range, forceMetadata: true)
    let statuses = try await h.repo.accounts().map(\.status)
    #expect(statuses.contains(.healthy)); #expect(statuses.contains(.needsReconnection))
}
@Test func searchFiltersCannotInjectSQLAndHideDoesNotStopSync() async throws {
    let h = try await Harness.make()
    let key = h.data.calendars[0].key
    try await h.repo.setCalendarChoices(key, visible: false)
    #expect(try await h.repo.calendar(key)?.syncEnabled == true)
    _ = try await h.repo.search("\" OR 1=1; DROP TABLE events; --")
    #expect(try await h.repo.accounts().count == 2)
    #expect(try await h.repo.search("Focus").count > 0)
}
@Test func crossAccountStageIsRejected() async throws {
    let h = try await Harness.make(); let source = try await h.repo.calendar(h.data.calendars[0].key)!
    let wrong = h.data.events.first { $0.key.calendar.account != source.key.account }!
    await #expect(throws: (any Error).self) { try await h.repo.stage([wrong], run: "bad", source: source) }
}
@Test func delayedAutosaveCannotResurrectSubmittedDraft() async throws {
    let h = try await Harness.make(); let m = h.create()
    let draft = EventDraft(id: m.id, calendar: m.key.calendar, fields: m.fields)
    try await h.repo.saveDraft(draft); try await h.repo.enqueue(m, draftID: draft.id); try await h.repo.saveDraft(draft)
    #expect(try await h.repo.snapshot(interval: range, displayZone: .gmt).drafts.isEmpty)
}
@Test func permissionRevocationBlocksQueuedWriteWithoutLosingIntent() async throws {
    let h = try await Harness.make(); let m = h.create(); try await h.repo.enqueue(m)
    var sources = h.data.calendars.filter { $0.key.account == m.key.calendar.account }
    for i in sources.indices { sources[i].role = "reader" }
    try await h.repo.reconcileCalendars(sources, account: m.key.calendar.account, generation: 0)
    await h.dispatcher.drain()
    #expect(await h.provider.writeCount == 0)
    #expect(try await h.repo.mutations().first?.fields["summary"] == .string("Saved offline"))
    #expect(try await h.repo.mutations().first?.state == .failed)
}
@Test func coupledTimeFieldsConflict() {
    let base: JSONObject = ["start": .string("a"), "end": .string("b")]
    #expect(ThreeWayMerge.conflicts(base: base, local: ["start": .string("c")], remote: ["start": .string("a"), "end": .string("d")]) == ["start"])
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["DAYFOLD_PERFORMANCE"] == "1")) func largeReferencePerformance() async throws {
    let now = InternetDate.parse("2026-11-05T12:00:00Z")!
    let data = FixtureFactory.demo(now: now, accountCount: 5, calendarsPerAccount: 10, eventCount: 100_000)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let repo = try CalendarRepository(path: directory.appendingPathComponent("performance.sqlite").path)
    for account in data.accounts { try await repo.connect(account); try await repo.reconcileCalendars(data.calendars.filter { $0.key.account == account.id }, account: account.id, generation: 0) }
    let clock = ContinuousClock(), begin = clock.now
    for source in data.calendars {
        let events = data.events.filter { $0.key.calendar == source.key }
        for offset in stride(from: 0, to: events.count, by: 1000) { try await repo.stage(Array(events[offset..<min(events.count, offset + 1000)]), run: source.id, source: source) }
        try await repo.publish(run: source.id, source: source, token: "benchmark", fingerprint: EventQuery.fingerprint, replaceResources: true)
    }
    print("PERF: baseline 100000 records, 5 accounts, 50 calendars: \(begin.duration(to: clock.now))")
    var queryTimes: [Double] = [], searchTimes: [Double] = [], layoutTimes: [Double] = [], saveTimes: [Double] = []
    let week = DateInterval(start: now.addingTimeInterval(-3 * 86400), duration: 7 * 86400)
    for _ in 0..<20 {
        let begin = clock.now; _ = try await repo.snapshot(interval: week, displayZone: .gmt); queryTimes.append(milliseconds(begin.duration(to: clock.now)))
        let search = clock.now; _ = try await repo.search("Design"); searchTimes.append(milliseconds(search.duration(to: clock.now)))
    }
    print("PERF: visible week p50=\(queryTimes.sorted()[10])ms p95=\(queryTimes.sorted()[18])ms; FTS p50=\(searchTimes.sorted()[10])ms p95=\(searchTimes.sorted()[18])ms")
    var dense = Array(data.events.prefix(700))
    for i in dense.indices {
        let start = week.start.addingTimeInterval(Double(i % 7) * 86_400 + Double(i % 4) * 900)
        dense[i].raw.merge(EventTime.timed(start: start, end: start.addingTimeInterval(3600), startZone: "UTC", endZone: "UTC").providerFields) { _, value in value }
    }
    for i in 0..<20 {
        let begin = clock.now
        for day in 0..<7 { _ = TimelineLayout.place(dense, day: DateInterval(start: week.start.addingTimeInterval(Double(day) * 86_400), duration: 86_400), zone: .gmt) }
        layoutTimes.append(milliseconds(begin.duration(to: clock.now)))
        let draft = EventDraft(calendar: data.calendars[0].key, fields: ["summary": .string("Performance draft \(i)")])
        let save = clock.now; try await repo.saveDraft(draft); saveTimes.append(milliseconds(save.duration(to: clock.now)))
    }
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    print("PERF: dense week 700 timed events layout p50=\(layoutTimes.sorted()[10])ms p95=\(layoutTimes.sorted()[18])ms; durable draft save p50=\(saveTimes.sorted()[10])ms p95=\(saveTimes.sorted()[18])ms; process peak RSS=\(Double(usage.ru_maxrss) / 1_048_576)MiB")
    #expect(try await repo.accounts().count == 5)
}
private func milliseconds(_ duration: Duration) -> Double { Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15 }
