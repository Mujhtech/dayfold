import Foundation
import Testing
@testable import CalendarCore

private struct RelayFixtureReply: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var body = Data()
    var finalURL: URL?
    init(_ json: String = "", status: Int = 200, headers: [String: String] = [:], finalURL: URL? = nil) {
        self.status = status; self.headers = headers; body = Data(json.utf8); self.finalURL = finalURL
    }
}

private final class ScriptedRelayTransport: RelayTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [RelayFixtureReply]
    private var recorded: [URLRequest] = []
    private var chunks: [Data] = []
    private var streamStatus = 200
    private var holdStream = false
    private var cancellations = 0
    init(_ replies: [RelayFixtureReply] = []) { self.replies = replies }
    var requests: [URLRequest] { lock.withLock { recorded } }
    var cancelledStreams: Int { lock.withLock { cancellations } }
    func configureStream(chunks: [Data], status: Int = 200, hold: Bool = false) {
        lock.withLock { self.chunks = chunks; streamStatus = status; holdStream = hold }
    }
    func send(_ request: URLRequest) async throws -> RelayHTTPResponse {
        let reply = try lock.withLock {
            recorded.append(request)
            guard !replies.isEmpty else { throw RelayClientError.transport }
            return replies.removeFirst()
        }
        return RelayHTTPResponse(head: RelayHTTPHead(url: reply.finalURL ?? request.url!, status: reply.status, headers: reply.headers), body: reply.body)
    }
    func stream(_ request: URLRequest) -> RelayTransportStream {
        let (chunks, status, hold) = lock.withLock {
            recorded.append(request)
            return (self.chunks, streamStatus, holdStream)
        }
        let pair = AsyncThrowingStream<RelayTransportEvent, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        pair.continuation.yield(.response(RelayHTTPHead(url: request.url!, status: status, headers: ["Content-Type": "text/event-stream; charset=utf-8"])))
        for chunk in chunks { pair.continuation.yield(.data(chunk)) }
        if !hold { pair.continuation.finish() }
        return RelayTransportStream(events: pair.stream, cancel: { [self] in
            lock.withLock { cancellations += 1 }
            pair.continuation.finish(throwing: RelayClientError.cancelled)
        })
    }
}

private let relayFixtureToken = String(repeating: "a", count: 64)
private let relayFixtureID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
private let relayFixtureSubject = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
private let relayFixtureOrigin = URL(string: "https://relay.example.test")!

private func relayNotificationJSON(sequence: Int64 = 8, kind: String = "calendar_changed", revision: String = "null") -> String {
    """
    {"sequence":\(sequence),"id":"\(relayFixtureID)","kind":"\(kind)","subject_id":"\(relayFixtureSubject)","revision":\(revision),"created_at":"2026-11-06T12:00:00.123456Z","expires_at":"2026-11-06T13:00:00Z"}
    """
}

private func relayFrame(sequence: Int64, id: Int64? = nil) -> String {
    "event: notification\r\nid: \(id ?? sequence)\r\ndata: \(relayNotificationJSON(sequence: sequence))\r\n\r\n"
}

private func eventually(_ predicate: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !predicate(), ContinuousClock.now < deadline { await Task.yield() }
    return predicate()
}

@Test func relayOriginsRequireHTTPSExceptExplicitLoopbackAndCredentialsStayRedacted() throws {
    for value in ["http://relay.example.test", "https://user:secret@relay.example.test", "https://relay.example.test/path", "https://relay.example.test/?query=1", "https://relay.example.test/#fragment"] {
        #expect(throws: RelayClientError.invalidConfiguration) { try RelayEndpoint.validatedOrigin(URL(string: value)!) }
    }
    #expect(throws: RelayClientError.invalidConfiguration) { try RelayEndpoint.validatedOrigin(URL(string: "http://127.0.0.1:8080")!) }
    #expect(try RelayEndpoint.validatedOrigin(URL(string: "http://127.0.0.1:8080")!, allowLoopbackHTTP: true).absoluteString == "http://127.0.0.1:8080/")
    #expect(throws: RelayClientError.invalidConfiguration) { try RelayEndpoint.validatedOrigin(URL(string: "http://localhost.example.test")!, allowLoopbackHTTP: true) }
    #expect(throws: RelayClientError.invalidConfiguration) { try RelayEndpoint.validateToken(relayFixtureToken + "\r\n") }
    let client = try RelayClient(baseURL: relayFixtureOrigin, token: relayFixtureToken)
    let reservation = RelayChannelReservation(id: relayFixtureID, token: relayFixtureToken, address: relayFixtureOrigin, expiresAt: Date())
    #expect(!String(reflecting: client).contains(relayFixtureToken))
    #expect(!String(reflecting: reservation).contains(relayFixtureToken))
}

@Test func relayEndpointsUseAuthenticatedHeadersExactWireFieldsAndFractionalDates() async throws {
    let channelToken = String(repeating: "b", count: 64)
    let http = ScriptedRelayTransport([
        .init(#"{"apns_enabled":true}"#),
        .init(#"{"floor":0,"current":8}"#),
        .init("{\"notifications\":[\(relayNotificationJSON())],\"cursor_floor\":0,\"latest_sequence\":8}"),
        .init(status: 204), .init(#"{"claimed":true}"#),
        .init("{\"id\":\"\(relayFixtureID)\",\"token\":\"\(channelToken)\",\"address\":\"https://relay.example.test/v1/webhooks/google\",\"expires_at\":\"2026-11-07T12:00:00.123Z\"}", status: 201),
        .init("{}"), .init(status: 204), .init(status: 204), .init(status: 204), .init(status: 204), .init(status: 204)
    ])
    let client = try RelayClient(baseURL: relayFixtureOrigin, token: relayFixtureToken, transport: http)
    let capabilities = try await client.capabilities()
    #expect(capabilities.apnsEnabled)
    #expect(try await client.cursor() == RelayCursor(floor: 0, current: 8))
    let page = try await client.notifications(after: 7)
    #expect(page.notifications.count == 1)
    #expect(page.notifications[0].subjectID == relayFixtureSubject)
    #expect(abs(page.notifications[0].createdAt.timeIntervalSince1970 - 1_793_966_400.123456) < 0.001)
    #expect(page.notifications[0].expiresAt > page.notifications[0].createdAt)
    try await client.acknowledge(sequence: 8)
    #expect(try await client.claimReminder(notificationID: relayFixtureID))
    let date = Date(timeIntervalSince1970: 1_794_052_800.125)
    let reservation = try await client.reserveChannel(scopeID: relayFixtureSubject, expiresAt: date)
    #expect(reservation.token == channelToken)
    try await client.activateChannel(id: relayFixtureID, resourceID: "opaque-resource", expiresAt: date)
    try await client.revokeChannel(id: relayFixtureID)
    try await client.putReminder(id: relayFixtureSubject, revision: 4, dueAt: date, expiresAt: date.addingTimeInterval(600))
    try await client.deleteReminder(id: relayFixtureSubject, revision: 5)
    try await client.registerPush(token: String(repeating: "AB", count: 32), environment: .sandbox)
    try await client.revokeDevice()
    let requests = http.requests
    #expect(requests.count == 12)
    #expect(requests.map(\.httpMethod) == ["GET", "GET", "GET", "POST", "POST", "POST", "PUT", "DELETE", "PUT", "DELETE", "PUT", "DELETE"])
    #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(relayFixtureToken)" && !($0.url?.absoluteString.contains(relayFixtureToken) ?? true) })
    #expect(requests[2].url?.query == "after=7")
    #expect(requests[4].url?.path == "/v1/notifications/\(relayFixtureID)/claim")
    #expect(requests[9].url?.query == "revision=5")
    let reminder = try JSONSerialization.jsonObject(with: requests[8].httpBody!) as! [String: Any]
    #expect(Set(reminder.keys) == ["revision", "due_at", "expires_at"])
    #expect((reminder["due_at"] as? String)?.contains(".125Z") == true)
    let reserved = try JSONSerialization.jsonObject(with: requests[5].httpBody!) as! [String: Any]
    #expect(Set(reserved.keys) == ["scope_id", "expires_at"])
    let registered = try JSONSerialization.jsonObject(with: requests[10].httpBody!) as! [String: Any]
    #expect(registered["token"] as? String == String(repeating: "ab", count: 32))
    #expect(registered["environment"] as? String == "sandbox")
}

@Test func relayHTTPFailuresAreTypedSanitizedAndNeverAutomaticallyRetried() async throws {
    let http = ScriptedRelayTransport([
        .init("secret-response-body", status: 401), .init(status: 410),
        .init(status: 429, headers: ["Retry-After": "60"]),
        .init(status: 503, headers: ["retry-after": "120"]), .init(status: 409)
    ])
    let client = try RelayClient(baseURL: relayFixtureOrigin, token: relayFixtureToken, transport: http)
    await #expect(throws: RelayClientError.unauthorized) { try await client.cursor() }
    await #expect(throws: RelayClientError.resyncRequired) { try await client.cursor() }
    await #expect(throws: RelayClientError.rateLimited(retryAfter: 60)) { try await client.reserveChannel(scopeID: relayFixtureSubject, expiresAt: Date()) }
    await #expect(throws: RelayClientError.unavailable(retryAfter: 120)) { try await client.cursor() }
    await #expect(throws: RelayClientError.rejected(status: 409)) { try await client.cursor() }
    #expect(http.requests.count == 5)
    #expect(!RelayClientError.unauthorized.localizedDescription.contains("secret-response-body"))
    #expect(RelayClient.retryAfter("Fri, 06 Nov 2026 12:01:00 GMT", now: RelayJSON.parseInternetDate("2026-11-06T12:00:00Z")!) == 60)
    #expect(RelayClient.retryAfter("NaN") == nil)
    #expect(RelayClient.retryAfter("-1") == nil)
}

@Test func relaySuccessfulResponsesRejectMalformedDatesCursorsAndRedirectedURLs() async throws {
    let malformed = relayNotificationJSON().replacingOccurrences(of: "2026-11-06T12:00:00.123456Z", with: "not-a-date")
    let http = ScriptedRelayTransport([
        .init("{\"notifications\":[\(malformed)],\"cursor_floor\":0,\"latest_sequence\":8}"),
        .init(#"{"floor":3,"current":2}"#),
        .init(#"{"floor":0,"current":0}"#, finalURL: URL(string: "https://different.example.test/v1/notifications/cursor")!),
        .init("{\"notifications\":[\(relayNotificationJSON())],\"cursor_floor\":0,\"latest_sequence\":7}")
    ])
    let client = try RelayClient(baseURL: relayFixtureOrigin, token: relayFixtureToken, transport: http)
    await #expect(throws: RelayClientError.invalidResponse) { try await client.notifications(after: 0) }
    await #expect(throws: RelayClientError.invalidResponse) { try await client.cursor() }
    await #expect(throws: RelayClientError.invalidResponse) { try await client.cursor() }
    await #expect(throws: RelayClientError.invalidResponse) { try await client.notifications(after: 0) }
}

@Test func relaySSEParsesSplitCRLFCommentsMultilineDataAndFractionalDates() throws {
    let json = relayNotificationJSON().replacingOccurrences(of: ",\"kind\"", with: ",\r\ndata: \"kind\"")
    let frame = "\u{FEFF}: keepalive\r\n\r\nevent: notification\r\nid: 8\r\ndata: \(json)\r\n\r\n"
    var parser = RelaySSEParser()
    var decoded: [RelayStreamEvent] = []
    for byte in frame.utf8 { decoded += try parser.append(Data([byte])) }
    try parser.finish()
    #expect(decoded.count == 1)
    if case .notification(let notification) = decoded.first {
        #expect(notification.sequence == 8)
        #expect(notification.subjectID == relayFixtureSubject)
    } else { Issue.record("notification frame was not decoded") }
    #expect(try parser.append(Data("event: resync_required\ndata: {}\n\n".utf8)) == [.resyncRequired])
}

@Test func relaySSERejectsMismatchedIDsInvalidUTF8OversizedEventsAndTruncation() throws {
    var mismatch = RelaySSEParser()
    #expect(throws: RelayClientError.invalidResponse) { try mismatch.append(Data(relayFrame(sequence: 8, id: 9).utf8)) }
    var invalidUTF8 = RelaySSEParser()
    #expect(throws: RelayClientError.invalidResponse) { try invalidUTF8.append(Data([0xFF, 10])) }
    var oversized = RelaySSEParser()
    _ = try oversized.append(Data(repeating: 65, count: 32 * 1024))
    _ = try oversized.append(Data(repeating: 65, count: 32 * 1024))
    #expect(throws: RelayClientError.invalidResponse) { try oversized.append(Data([65])) }
    var truncated = RelaySSEParser()
    _ = try truncated.append(Data("event: notification\nid: 8\ndata: {".utf8))
    #expect(throws: RelayClientError.invalidResponse) { try truncated.finish() }
    var noRevision = RelaySSEParser()
    let reminder = "event: notification\nid: 8\ndata: \(relayNotificationJSON(kind: "reminder_due"))\n\n"
    #expect(throws: RelayClientError.invalidResponse) { try noRevision.append(Data(reminder.utf8)) }
}

@Test func relaySSEReconnectUsesDurableCursorWithoutImplicitAcknowledgement() async throws {
    let http = ScriptedRelayTransport()
    http.configureStream(chunks: [Data((relayFrame(sequence: 8) + relayFrame(sequence: 9)).utf8)])
    let client = try RelayClient(baseURL: relayFixtureOrigin, token: relayFixtureToken, transport: http)
    var sequences: [Int64] = []
    for try await event in client.events(after: 7) {
        if case .notification(let notification) = event { sequences.append(notification.sequence) }
    }
    http.configureStream(chunks: [Data(relayFrame(sequence: 10).utf8)])
    for try await event in client.events(after: 9) {
        if case .notification(let notification) = event { sequences.append(notification.sequence) }
    }
    #expect(sequences == [8, 9, 10])
    #expect(http.requests.count == 2)
    #expect(http.requests.map { $0.value(forHTTPHeaderField: "Last-Event-ID") } == ["7", "9"])
    #expect(http.requests.allSatisfy { $0.httpMethod == "GET" && $0.url?.path == "/v1/events" && $0.url?.query == nil })
    #expect(http.cancelledStreams == 2)
}

@Test func relaySSECancellationClosesItsUnderlyingConnection() async throws {
    let http = ScriptedRelayTransport()
    http.configureStream(chunks: [], hold: true)
    let client = try RelayClient(baseURL: relayFixtureOrigin, token: relayFixtureToken, transport: http)
    let consumer = Task { for try await _ in client.events(after: 0) {} }
    #expect(await eventually { http.requests.count == 1 })
    consumer.cancel()
    _ = await consumer.result
    #expect(await eventually { http.cancelledStreams == 1 })
}

@Test func relaySSESlowConsumersGetBoundedReplayableOverflow() async throws {
    let http = ScriptedRelayTransport()
    http.configureStream(chunks: [Data((1...70).map { relayFrame(sequence: Int64($0)) }.joined().utf8)])
    let client = try RelayClient(baseURL: relayFixtureOrigin, token: relayFixtureToken, transport: http)
    let stream = client.events(after: 0)
    #expect(await eventually { http.cancelledStreams == 1 })
    var delivered = 0
    do {
        for try await _ in stream { delivered += 1 }
        Issue.record("overflow should require reconnect and replay")
    } catch { #expect(error as? RelayClientError == .streamOverflow) }
    #expect(delivered == 64)
}

private struct RelayURLFixture: Sendable {
    var redirect: URL?
    var hold = false
}

private final class RelayURLFixtureRegistry: @unchecked Sendable {
    static let shared = RelayURLFixtureRegistry()
    private let lock = NSLock()
    private var fixtures: [URL: RelayURLFixture] = [:]
    private var requests: [URLRequest] = []
    private var stopped: Set<URL> = []
    func install(_ fixture: RelayURLFixture, for url: URL) { lock.withLock { fixtures[url] = fixture } }
    func record(_ request: URLRequest) -> RelayURLFixture? {
        lock.withLock { requests.append(request); return request.url.flatMap { fixtures[$0] } }
    }
    func count(_ url: URL) -> Int { lock.withLock { requests.filter { $0.url == url }.count } }
    func stop(_ url: URL?) { lock.withLock { if let url { stopped.insert(url) } } }
    func didStop(_ url: URL) -> Bool { lock.withLock { stopped.contains(url) } }
}

private final class RelayURLProtocolFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = RelayURLFixtureRegistry.shared.record(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        if fixture.hold { return }
        if let destination = fixture.redirect {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": destination.absoluteString])!
            var redirected = URLRequest(url: destination)
            redirected.setValue(request.value(forHTTPHeaderField: "Authorization"), forHTTPHeaderField: "Authorization")
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"floor":0,"current":0}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { RelayURLFixtureRegistry.shared.stop(request.url) }
}

private func relayURLFixtureTransport() -> RelayURLSessionTransport {
    RelayURLSessionTransport(configurationFactory: {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RelayURLProtocolFixture.self]
        return configuration
    })
}

@Test func relayURLSessionRejectsRedirectsBeforeCredentialsReachAnotherOrigin() async throws {
    let origin = URL(string: "https://\(UUID().uuidString.lowercased()).example.test")!
    let endpoint = origin.appendingPathComponent("v1/notifications/cursor")
    let destination = URL(string: "https://\(UUID().uuidString.lowercased()).example.test/redirected")!
    let registry = RelayURLFixtureRegistry.shared
    registry.install(RelayURLFixture(redirect: destination), for: endpoint)
    registry.install(RelayURLFixture(), for: destination)
    let client = try RelayClient(baseURL: origin, token: relayFixtureToken, transport: relayURLFixtureTransport())
    await #expect(throws: RelayClientError.rejected(status: 302)) { try await client.cursor() }
    #expect(registry.count(endpoint) == 1)
    #expect(registry.count(destination) == 0)
}

@Test func relayURLSessionCancellationStopsTheActualRequest() async throws {
    let origin = URL(string: "https://\(UUID().uuidString.lowercased()).example.test")!
    let endpoint = origin.appendingPathComponent("v1/notifications/cursor")
    let registry = RelayURLFixtureRegistry.shared
    registry.install(RelayURLFixture(hold: true), for: endpoint)
    let client = try RelayClient(baseURL: origin, token: relayFixtureToken, transport: relayURLFixtureTransport())
    let request = Task { try await client.cursor() }
    #expect(await eventually { registry.count(endpoint) == 1 })
    request.cancel()
    do { _ = try await request.value; Issue.record("cancelled request unexpectedly succeeded") }
    catch { #expect(error as? RelayClientError == .cancelled) }
    #expect(await eventually { registry.didStop(endpoint) })
}
