import Foundation
import Testing
import GRDB
@testable import CalendarCore

extension CalendarRepository {
    func exhaustPagesForTest() throws {
        try database.write { db in
            let count = try Int.fetchOne(db, sql: "PRAGMA page_count")!
            try db.execute(sql: "PRAGMA max_page_count = \(count)")
        }
    }
}
@Test func diskFailureDoesNotAcknowledgeOrDeleteDraft() async throws {
    let h = try await Harness.make()
    var m = h.create(); m.fields["description"] = .string(String(repeating: "Calendar content ", count: 100_000))
    let draft = EventDraft(id: m.id, calendar: m.key.calendar, fields: ["summary": .string("My draft")])
    try await h.repo.saveDraft(draft); try await h.repo.exhaustPagesForTest()
    await #expect(throws: (any Error).self) { try await h.repo.enqueue(m, draftID: draft.id) }
    #expect(try await h.repo.mutations().isEmpty)
    let snapshot = try await h.repo.snapshot(interval: DateInterval(start: .distantPast, end: .distantFuture), displayZone: .gmt)
    #expect(snapshot.drafts.contains { $0.id == draft.id })
}
@Test func newerSchemaRefusedAndCorruptOriginalPreserved() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let newer = dir.appendingPathComponent("newer.sqlite").path
    let db = try DatabaseQueue(path: newer); try db.write { try $0.execute(sql: "PRAGMA user_version=99") }
    #expect(throws: CalendarError.incompatibleSchema) { try CalendarRepository(path: newer) }
    let corrupt = dir.appendingPathComponent("corrupt.sqlite"), bytes = Data("Preserve original damaged file".utf8)
    try bytes.write(to: corrupt)
    #expect(throws: (any Error).self) { try CalendarRepository(path: corrupt.path) }
    #expect(try Data(contentsOf: corrupt) == bytes)
}
@Test func monthSpansRemainStableAndEndExclusive() throws {
    let start = InternetDate.parse("2026-11-02T00:00:00Z")!
    var data = FixtureFactory.demo(now: start, accountCount: 1, calendarsPerAccount: 1, eventCount: 2)
    data.events[0].raw.merge(EventTime.allDay(start: try LocalDate("2026-11-04"), end: try LocalDate("2026-11-11")).providerFields) { _, v in v }
    data.events[1].raw.merge(EventTime.allDay(start: try LocalDate("2026-11-02"), end: try LocalDate("2026-11-04")).providerFields) { _, v in v }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt; calendar.firstWeekday = 2
    let spans = MonthSpanLayout.spans(events: data.events, gridStart: start, calendar: calendar)
    let across = spans.filter { $0.event.id == data.events[0].id }
    #expect(across.count == 2); #expect(across[0].length == 5); #expect(across[1].length == 2)
    #expect(across[0].row == across[1].row)
    #expect(spans.filter { $0.week == 0 }.allSatisfy { $0.row == 0 })
}
