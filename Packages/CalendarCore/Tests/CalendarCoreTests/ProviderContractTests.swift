import Foundation
import Testing
@testable import CalendarCore

private actor TokenFixture: AccessTokenSource {
    var forced: [Bool] = []
    func accessToken(for account: AccountID, forceRefresh: Bool) async throws -> String {
        forced.append(forceRefresh); return forceRefresh ? "fixture-refreshed" : "fixture-cached"
    }
}
private actor ScriptedHTTP: HTTPTransport {
    var responses: [HTTPResponse]
    var requests: [URLRequest] = []
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw ProviderError.network }
        return responses.removeFirst()
    }
}
private func response(_ raw: JSONObject, status: Int = 200) throws -> HTTPResponse {
    HTTPResponse(data: try JSONEncoder().encode(raw), status: status)
}

@Test func googleUnauthorizedRefreshesExactlyOnce() async throws {
    let tokens = TokenFixture(), key = EventKey(calendar: CalendarKey(account: AccountID(), calendarID: "opaque/a+calendar@example.com"), eventID: "event")
    let http = ScriptedHTTP(try [response([:], status: 401), response(["id": .string("event")])])
    let provider = GoogleCalendarProvider(tokens: tokens, transport: http)
    _ = try await provider.event(key, zone: "UTC")
    #expect(await tokens.forced == [false, true])
    #expect(await http.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-refreshed")
    let rejected = ScriptedHTTP(try [response([:], status: 401), response([:], status: 401)])
    await #expect(throws: ProviderError.unauthorized) { try await GoogleCalendarProvider(tokens: TokenFixture(), transport: rejected).event(key, zone: "UTC") }
    #expect(await rejected.requests.count == 2)
}

@Test func googlePatchAndDeleteUseNarrowConditionalRequests() async throws {
    let key = EventKey(calendar: CalendarKey(account: AccountID(), calendarID: "a/b+#?@example.com"), eventID: "one/two")
    let raw: JSONObject = ["id": .string(key.eventID), "etag": .string("new")]
    let http = ScriptedHTTP(try [response(raw), HTTPResponse(data: Data(), status: 204)])
    let provider = GoogleCalendarProvider(tokens: TokenFixture(), transport: http)
    let patch = Mutation(key: key, kind: .patch, fields: ["summary": .string("Changed"), "location": .null], base: CalendarEvent(key: key, raw: raw))
    _ = try await provider.write(patch, etag: "opaque-etag", zone: "UTC")
    _ = try await provider.write(Mutation(key: key, kind: .delete, fields: [:], base: patch.base), etag: "new", zone: "UTC")
    let requests = await http.requests
    #expect(requests[0].httpMethod == "PATCH"); #expect(requests[0].value(forHTTPHeaderField: "If-Match") == "opaque-etag")
    #expect(try JSONDecoder().decode(JSONObject.self, from: requests[0].httpBody!) == patch.fields)
    #expect(requests[0].url!.absoluteString.contains("one%2Ftwo"))
    #expect(requests[1].httpMethod == "DELETE" && requests[1].httpBody == nil)
    #expect(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems == [URLQueryItem(name: "sendUpdates", value: "all")])
}

@Test func malformedPageAndAvailabilityNeverBecomeEmptySuccess() async throws {
    let source = CalendarSource(key: CalendarKey(account: AccountID(), calendarID: "calendar"), title: "Source")
    let window = DateInterval(start: Date(), duration: 3600)
    let http = ScriptedHTTP(try [response([:]), response(["calendars": .object(["calendar": .object(["errors": .array([.object(["reason": .string("notFound")])])])])]), response(["calendars": .object(["calendar": .object(["busy": .array([.object(["start": .string("invalid"), "end": .string("also invalid")])])])])])])
    let provider = GoogleCalendarProvider(tokens: TokenFixture(), transport: http)
    await #expect(throws: ProviderError.malformed) { try await provider.calendars(account: source.key.account, page: nil) }
    await #expect(throws: ProviderError.forbidden) { try await provider.busy(source: source, window: window) }
    await #expect(throws: ProviderError.malformed) { try await provider.busy(source: source, window: window) }
}

private actor RefreshCounter {
    var calls = 0
    func perform() async throws -> String { calls += 1; try await Task.sleep(for: .milliseconds(60)); return "fixture" }
}
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; for waiter in waiters { waiter.resume() }; waiters = [] }
}

@Test func tokenRefreshIsSingleFlightPerAccount() async throws {
    let pool = TokenRequestPool(), counter = RefreshCounter(), account = AccountID()
    try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<20 { group.addTask { try await pool.value(for: account, forceRefresh: true) { _ in try await counter.perform() } } }
        for try await value in group { #expect(value == "fixture") }
    }
    #expect(await counter.calls == 1)
}

@Test func lateTokenCannotRepopulateDisconnectedAccount() async throws {
    let pool = TokenRequestPool(), entered = Gate(), release = Gate(), account = AccountID()
    let task = Task { try await pool.value(for: account, forceRefresh: true) { _ in await entered.release(); await release.wait(); return "late fixture" } }
    await entered.wait(); await pool.invalidate(account); await release.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await pool.value(for: account, forceRefresh: false) { _ in "new fixture" } == "new fixture")
}

@Test func coalescedAndDiscardedDraftsRejectLateAutosaves() async throws {
    let h = try await Harness.make(), create = h.create()
    try await h.repo.enqueue(create)
    let edit = EventDraft(calendar: create.key.calendar, fields: ["summary": .string("Final title")])
    try await h.repo.saveDraft(edit)
    try await h.repo.enqueue(Mutation(id: edit.id, key: create.key, kind: .patch, fields: edit.fields, base: CalendarEvent(key: create.key, raw: create.fields)), draftID: edit.id)
    try await h.repo.saveDraft(edit)
    let discarded = EventDraft(calendar: create.key.calendar, fields: ["summary": .string("Discarded")])
    try await h.repo.saveDraft(discarded); try await h.repo.discardDraft(discarded.id); try await h.repo.saveDraft(discarded)
    #expect(try await h.repo.snapshot(interval: DateInterval(start: .distantPast, end: .distantFuture), displayZone: .gmt).drafts.isEmpty)
}
