import Foundation
import Testing
@testable import CalendarCore

@Test func confirmedUndoPreservesUnrelatedChangesAndCanBeReversed() async throws {
    let h = try await Harness.make()
    let event = h.data.events.first { $0.key.calendar == h.data.calendars[0].key && $0.selfAttendee == nil }!
    let edit = Mutation(key: event.key, kind: .patch, fields: ["summary": .string("Revised title")], base: event)
    try await h.repo.enqueue(edit); await h.dispatcher.drain()
    let restarted = try CalendarRepository(path: h.path)
    try await h.provider.remoteEdit(event.key, fields: ["location": .string("Updated room")])
    let undo = try await restarted.reverseConfirmed(edit.id)
    let dispatcher = MutationDispatcher(repository: restarted, provider: h.provider, gate: CalendarWorkGate())
    await dispatcher.drain()
    var remote = try await h.provider.event(event.key, zone: "UTC")
    #expect(remote.title == event.title); #expect(remote.location == "Updated room")
    try await restarted.reverseConfirmed(undo.id); await dispatcher.drain()
    remote = try await h.provider.event(event.key, zone: "UTC")
    #expect(remote.title == "Revised title"); #expect(remote.location == "Updated room")
}

@Test func undoDoesNotOverwriteConcurrentSameFieldEdit() async throws {
    let h = try await Harness.make()
    let event = h.data.events.first { $0.key.calendar == h.data.calendars[0].key && $0.selfAttendee == nil }!
    let edit = Mutation(key: event.key, kind: .patch, fields: ["summary": .string("Local revision")], base: event)
    try await h.repo.enqueue(edit); await h.dispatcher.drain()
    try await h.provider.remoteEdit(event.key, fields: ["summary": .string("Someone else's change")])
    let undo = try await h.repo.reverseConfirmed(edit.id); await h.dispatcher.drain()
    #expect(try await h.repo.mutation(undo.id)?.state == .conflicted)
    #expect(try await h.provider.event(event.key, zone: "UTC").title == "Someone else's change")
}

@Test func cancelledOrChangedPreflightCannotExecute() async throws {
    let h = try await Harness.make(), create = h.create()
    try await h.repo.enqueue(create); try await h.repo.cancelQueued(create.id)
    #expect(try await h.repo.beginExecution(create) == nil)
    var lateFailure = create; lateFailure.state = .retryScheduled
    try await h.repo.transition(lateFailure)
    #expect(try await h.repo.mutation(create.id)?.state == .cancelled)
    let next = h.create(); try await h.repo.enqueue(next)
    try await h.repo.enqueue(Mutation(key: next.key, kind: .patch, fields: ["summary": .string("Later edit")], base: CalendarEvent(key: next.key, raw: next.fields)))
    #expect(try await h.repo.beginExecution(next) == nil)
    await h.dispatcher.drain()
    #expect(try await h.provider.event(next.key, zone: "UTC").title == "Later edit")
    #expect(await h.provider.writeCount == 1)
}

@Test func nullPatchReconciliationAndInternetDates() {
    #expect(ThreeWayMerge.applied(["location": .null], to: [:]))
    #expect(ThreeWayMerge.conflicts(base: ["location": .null], local: ["location": .string("Room")], remote: [:]).isEmpty)
    #expect(InternetDate.parse("2026-11-05T14:00:00+01:00") == InternetDate.parse("2026-11-05T13:00:00Z"))
    let fractional = InternetDate.parse("2026-11-05T13:00:00.125Z")!
    #expect(abs(fractional.timeIntervalSince(InternetDate.parse("2026-11-05T13:00:00Z")!) - 0.125) < 0.001)
    #expect(InternetDate.parse("not a date") == nil)
}
