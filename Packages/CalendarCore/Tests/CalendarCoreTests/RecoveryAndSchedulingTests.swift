import Foundation
import Testing
@testable import CalendarCore

@Test func invitedCopyRemovalDoesNotGrantOrganizerEdits() {
    let data = FixtureFactory.demo(accountCount: 1, calendarsPerAccount: 1, eventCount: 1), event = data.events[0]
    #expect(!event.organizerIsSelf && event.selfAttendee != nil)
    #expect(EventCapabilityResolver.resolve(.delete, account: data.accounts[0], calendar: data.calendars[0], event: event).allowed)
    #expect(!EventCapabilityResolver.resolve(.edit, account: data.accounts[0], calendar: data.calendars[0], event: event).allowed)
    var readOnly = data.calendars[0]; readOnly.role = "reader"
    #expect(!EventCapabilityResolver.resolve(.delete, account: data.accounts[0], calendar: readOnly, event: event).allowed)
}

@Test func earlierPreferencesRetainValuesAndGainDefaults() throws {
    let preferences = try JSONDecoder().decode(Preferences.self, from: Data(#"{"defaultDuration":45,"displayZone":"Asia/Kathmandu"}"#.utf8))
    #expect(preferences.defaultDuration == 45 && preferences.displayZone == "Asia/Kathmandu")
    #expect(preferences.startupView == "restore" && preferences.showWeekends)
}

@Test func onboardingPreferencesPreserveLegacyStateAndResumeActiveStep() throws {
    let decoder = JSONDecoder()
    var preferences = try decoder.decode(Preferences.self, from: Data(#"{"defaultDuration":45,"notifications":true}"#.utf8))
    #expect(preferences.onboardingStep == nil)
    preferences.onboardingStep = "reminders"
    let restored = try decoder.decode(Preferences.self, from: JSONEncoder().encode(preferences))
    #expect(restored.onboardingStep == "reminders")
    #expect(restored.defaultDuration == 45 && restored.notifications)
}

@Test func rejectedCreateCorrectionKeepsIdentityAndDependencies() async throws {
    let h = try await Harness.make(), create = h.create()
    try await h.repo.enqueue(create); await h.provider.failNext(.invalid); await h.dispatcher.drain()
    #expect(try await h.repo.mutation(create.id)?.state == .failed)
    let draft = try await h.repo.correctionDraft(for: create.id)
    let later = Mutation(key: create.key, kind: .patch, fields: ["location": .string("A later room")], base: CalendarEvent(key: create.key, raw: create.fields))
    try await h.repo.enqueue(later)
    var fields = draft.fields; fields["summary"] = .string("Corrected event")
    try await h.repo.reviseRejected(create.id, fields: fields, draftID: draft.id)
    await h.dispatcher.drain()
    let event = try await h.provider.event(create.key, zone: "UTC")
    #expect(event.title == "Corrected event" && event.location == "A later room")
    #expect(event.raw["extendedProperties"]?["private"]["dayfoldOperation"].string == create.id)
    #expect(await h.provider.writeCount == 2)
    #expect(try await h.repo.mutations().filter { $0.state.pending }.isEmpty)
    await #expect(throws: (any Error).self) { try await h.repo.correctionDraft(for: create.id) }
}

@Test func latePreflightFailureCannotReplaceCoalescedIntent() async throws {
    let h = try await Harness.make(), create = h.create()
    try await h.repo.enqueue(create)
    try await h.repo.enqueue(Mutation(key: create.key, kind: .patch, fields: ["summary": .string("Newer intent")], base: CalendarEvent(key: create.key, raw: create.fields)))
    var obsolete = create; obsolete.state = .failed; obsolete.errorCategory = "invalid"
    try await h.repo.transition(obsolete)
    #expect(try await h.repo.mutation(create.id)?.state == .queued)
    #expect(try await h.repo.mutation(create.id)?.fields.text("summary") == "Newer intent")
}

@Test func editDuringInFlightCreateWaitsAndRebases() async throws {
    let h = try await Harness.make(), create = h.create()
    try await h.repo.enqueue(create)
    let claimed = try await h.repo.beginExecution(create)!
    let later = Mutation(key: create.key, kind: .patch, fields: ["summary": .string("After dispatch")], base: CalendarEvent(key: create.key, raw: create.fields))
    try await h.repo.enqueue(later)
    #expect(try await h.repo.mutation(later.id)?.predecessor == create.id)
    let result = try await h.provider.write(claimed, etag: nil, zone: "UTC")
    try await h.repo.confirm(claimed, event: result)
    #expect(try await h.repo.mutation(later.id)?.base?.etag == result?.etag)
    await h.dispatcher.drain()
    #expect(try await h.provider.event(create.key, zone: "UTC").title == "After dispatch")
}

@Test func unstartedRSVPCoalescesToFinalSelfResponse() async throws {
    let h = try await Harness.make(), event = h.data.events[0]
    for response in ["tentative", "accepted", "declined"] {
        let fields: JSONObject = ["attendeesOmitted": .bool(true), "attendees": .array([.object(["email": .string(event.selfAttendee!.text("email")), "responseStatus": .string(response)])])]
        try await h.repo.enqueue(Mutation(key: event.key, kind: .rsvp, fields: fields, base: event))
    }
    #expect(try await h.repo.mutations().filter { $0.state.pending }.count == 1)
    await h.dispatcher.drain()
    #expect(try await h.provider.event(event.key, zone: "UTC").response == "declined")
    #expect(await h.provider.writeCount == 1)
}

@Test func permissionLossRedactsRecoveryBaselineAndLateDraft() async throws {
    let h = try await Harness.make()
    let original = h.data.events.first { $0.key.calendar == h.data.calendars[0].key && $0.selfAttendee == nil }!
    var draft = EventDraft(calendar: original.key.calendar, source: original, fields: original.raw)
    draft.fields["summary"] = .string("My unsent title"); try await h.repo.saveDraft(draft)
    let work = Mutation(key: original.key, kind: .patch, fields: ["summary": .string("My unsent title")], base: original)
    try await h.repo.enqueue(work)
    try await h.repo.reconcileCalendars([], account: original.key.calendar.account, generation: 0)
    try await h.repo.saveDraft(draft)
    let recovered = try await h.repo.snapshot(interval: DateInterval(start: .distantPast, end: .distantFuture), displayZone: .gmt)
    #expect(recovered.drafts.first { $0.id == draft.id }?.fields == ["summary": .string("My unsent title")])
    #expect(try await h.repo.mutation(work.id)?.base?.descriptionText == "")
    #expect(try await h.repo.mutation(work.id)?.fields.text("summary") == "My unsent title")
    #expect(try await h.repo.search(original.title).contains(original.id) == false)
}

@Test func retryTimingSurvivesRestartAndCannotChangeReconnectedAccount() async throws {
    let h = try await Harness.make(), account = try await h.repo.account(h.data.accounts[0].id)!, now = Date()
    try await h.repo.recordSyncFailure(account, status: .throttled, now: now, minimumDelay: 120)
    let reopened = try CalendarRepository(path: h.path)
    #expect(try await reopened.account(account.id)?.retryAfter == now.addingTimeInterval(120))
    let reconnected = try await reopened.connect(account)
    try await reopened.recordSyncFailure(account, status: .offline, now: now)
    #expect(try await reopened.account(account.id)?.generation == reconnected.generation)
    #expect(try await reopened.account(account.id)?.status != .offline)
}

private actor BudgetProbe {
    var total = 0, maximum = 0
    var accounts: [AccountID: Int] = [:]
    var perAccountMaximum = 0
    var starts: [AccountID: [Date]] = [:]
    func enter(_ account: AccountID) {
        total += 1; maximum = max(maximum, total); accounts[account, default: 0] += 1
        perAccountMaximum = max(perAccountMaximum, accounts[account]!); starts[account, default: []].append(Date())
    }
    func leave(_ account: AccountID) { total -= 1; accounts[account, default: 0] -= 1 }
}

@Test func sharedRequestBudgetCapsConcurrencyAndRate() async throws {
    let budget = RequestBudget(policy: .init(globalConcurrent: 2, accountConcurrent: 1, globalRequests: 20, accountRequests: 2, interval: 0.12))
    let probe = BudgetProbe(), accounts = [AccountID(), AccountID()]
    try await withThrowingTaskGroup(of: Void.self) { group in
        for account in accounts { for _ in 0..<4 {
            group.addTask {
                try await budget.acquire(account); await probe.enter(account)
                try await Task.sleep(for: .milliseconds(5))
                await probe.leave(account); await budget.release(account)
            }
        } }
        try await group.waitForAll()
    }
    #expect(await probe.maximum <= 2); #expect(await probe.perAccountMaximum == 1)
    for times in await probe.starts.values { #expect(times.count == 4); #expect(times[2].timeIntervalSince(times[0]) >= 0.11) }
}

@Test func cancelledBudgetWaitDoesNotLeakPermit() async throws {
    let budget = RequestBudget(policy: .init(globalConcurrent: 1)), account = AccountID()
    try await budget.acquire(account)
    let waiting = Task { try await budget.acquire(account) }
    waiting.cancel()
    await #expect(throws: CancellationError.self) { try await waiting.value }
    await budget.release(account)
    try await budget.acquire(account); await budget.release(account)
}

@Test func denseAndZeroDurationEventsRemainDiscoverable() {
    let now = Date(), day = DateInterval(start: now.addingTimeInterval(-3600), duration: 86_400)
    var events = FixtureFactory.demo(now: now, accountCount: 1, calendarsPerAccount: 1, eventCount: 12).events
    for i in events.indices { events[i].raw.merge(EventTime.timed(start: now, end: now.addingTimeInterval(i == 0 ? 0 : 3600), startZone: "UTC", endZone: "UTC").providerFields) { _, value in value } }
    let placed = TimelineLayout.place(events, day: day, zone: .gmt)
    #expect(placed.count == 12)
    #expect(TimelineDensity.overflow(placed, maximumColumns: 4).map(\.count).reduce(0, +) == 9)
    #expect(TimelineLayout.place(events.reversed(), day: day, zone: .gmt).map(\.id) == placed.map(\.id))
    #expect(QuickEntryParser.parse("Meet tomorrow at 3pm for 999999999999999999999999 hours", now: now, zone: .gmt).time == nil)
}
