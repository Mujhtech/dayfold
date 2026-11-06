import Foundation
import GRDB
import Testing
@testable import CalendarCore

@Test func versionOneMigrationPreservesDraftsOutboxAndSearch() async throws {
    let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite").path
    let date = InternetDate.parse("2026-11-05T12:00:00Z")!
    let data = FixtureFactory.demo(now: date, accountCount: 1, calendarsPerAccount: 1, eventCount: 1)
    let account = data.accounts[0], source = data.calendars[0], event = data.events[0]
    let draft = EventDraft(calendar: source.key, fields: ["summary": .string("Retain my draft")])
    let work: Mutation = { var work = Mutation(key: event.key, kind: .rsvp, fields: [:], base: event); work.state = .executing; return work }()
    do {
        let legacy = try DatabaseQueue(path: path)
        let schema = try String(contentsOf: Bundle.module.url(forResource: "v1-schema", withExtension: "sql", subdirectory: "Fixtures")!, encoding: .utf8)
        try await legacy.write { db in
            try db.execute(sql: schema)
            try CalendarRepository.putAccount(account, db); try CalendarRepository.putCalendar(source, db)
            try CalendarRepository.put(draft, id: draft.id, table: "drafts", db: db); try CalendarRepository.putMutation(work, db)
            let interval = event.time!.interval(in: .gmt)
            try db.execute(sql: "INSERT INTO events VALUES(?,?,?,?,?,?)", arguments: [event.id, source.id, "resource", interval.start.timeIntervalSince1970, interval.end.timeIntervalSince1970, try JSONEncoder().encode(event)])
            try db.execute(sql: "INSERT INTO search_index VALUES(?,?)", arguments: [event.id, "Legacy searchable event"])
        }
    }
    let migrated = try CalendarRepository(path: path)
    let snapshot = try await migrated.snapshot(interval: DateInterval(start: .distantPast, end: .distantFuture), displayZone: .gmt)
    #expect(snapshot.drafts == [draft]); #expect(snapshot.events.count == 1)
    #expect(snapshot.mutations.first?.state == .uncertain)
    #expect(try await migrated.search("Legacy") == [event.id])
    #expect(try await CalendarRepository(path: path).account(account.id) != nil)
}

@Test func preservedStoreIncludesDatabaseAndSidecars() throws {
    let original = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "/Google", isDirectory: true)
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
    for name in ["calendar.sqlite", "calendar.sqlite-wal", "calendar.sqlite-shm"] { try Data(name.utf8).write(to: original.appendingPathComponent(name)) }
    let saved = try StoreRecovery.preserveAndCreateEmptyStore(at: original)
    #expect(try FileManager.default.contentsOfDirectory(atPath: original.path).isEmpty)
    for name in ["calendar.sqlite", "calendar.sqlite-wal", "calendar.sqlite-shm"] { #expect(try Data(contentsOf: saved.appendingPathComponent(name)) == Data(name.utf8)) }
}

@Test func cancelledMasterAndExceptionCannotBeResurrectedByWindow() async throws {
    let h = try await Harness.make()
    let source = try await h.repo.calendar(h.data.calendars[0].key)!
    let interval = DateInterval(start: InternetDate.parse("2026-10-01T00:00:00Z")!, end: InternetDate.parse("2026-12-01T00:00:00Z")!)
    var instance = h.data.events.first { $0.key.calendar == source.key }!
    instance.key = EventKey(calendar: source.key, eventID: "series_instance")
    instance.raw["id"] = .string(instance.key.eventID); instance.raw["recurringEventId"] = .string("series")
    instance.raw["originalStartTime"] = instance.raw["start"]
    try await h.repo.stage([instance], run: "first", source: source); try await h.repo.publish(run: "first", source: source, window: interval)
    let cancelled = CalendarEvent(key: EventKey(calendar: source.key, eventID: "series"), raw: ["id": .string("series"), "status": .string("cancelled")])
    try await h.repo.stage([cancelled], run: "cancel", source: source); try await h.repo.publish(run: "cancel", source: source, token: "new", fingerprint: EventQuery.fingerprint)
    try await h.repo.stage([instance], run: "late", source: source); try await h.repo.publish(run: "late", source: source, window: interval)
    #expect(try await h.repo.event(instance.key) == nil)
    #expect(try await h.repo.search(instance.title).contains(instance.id) == false)
    let reopened = try CalendarRepository(path: h.path)
    #expect(try await reopened.event(instance.key) == nil)
}

@Test func allDayAndMultipleRemindersKeepStableOrigins() throws {
    let now = InternetDate.parse("2026-11-05T00:00:00Z")!
    var data = FixtureFactory.demo(now: now, accountCount: 1, calendarsPerAccount: 1, eventCount: 1)
    data.calendars[0].timeZone = "Asia/Kathmandu"
    data.events[0].raw.merge(EventTime.allDay(start: try LocalDate("2026-11-05"), end: try LocalDate("2026-11-06")).providerFields) { _, v in v }
    data.events[0].raw["reminders"] = .object(["useDefault": .bool(false), "overrides": .array([.object(["method": .string("popup"), "minutes": .number(0)]), .object(["method": .string("popup"), "minutes": .number(10)]), .object(["method": .string("email"), "minutes": .number(10)])])])
    var prefs = Preferences(); prefs.notifications = true
    let plan = ReminderPlanner.plan(events: data.events, calendars: data.calendars, preferences: prefs, now: now)
    #expect(plan.count == 2); #expect(Set(plan.map(\.id)).count == 2)
    #expect(plan.last?.fire == InternetDate.parse("2026-11-05T03:15:00Z"))
    let after = InternetDate.parse("2026-11-05T04:00:00Z")!
    #expect(ReminderPlanner.plan(events: data.events, calendars: data.calendars, preferences: prefs, now: after).isEmpty)
    #expect(ReminderPlanner.plan(events: data.events, calendars: data.calendars, preferences: prefs, now: after, includeRecentPast: true).map(\.id) == plan.map(\.id))
    data.events[0].raw["status"] = .string("cancelled")
    #expect(ReminderPlanner.plan(events: data.events, calendars: data.calendars, preferences: prefs, now: after, includeRecentPast: true).isEmpty)
}
