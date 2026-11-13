import Foundation
import Testing
@testable import CalendarCore

private struct GoogleTransportFixture: Sendable {
    var status = 200
    var redirect: URL?
    var responseURL: URL?
    var headers: [String: String] = [:]
    var body = Data("{}".utf8)
    var hold = false
    var error: URLError?
}

private final class GoogleTransportRegistry: @unchecked Sendable {
    static let shared = GoogleTransportRegistry()
    private let lock = NSLock()
    private var fixtures: [URL: GoogleTransportFixture] = [:]
    private var requests: [URLRequest] = []
    private var stopped: Set<URL> = []
    func install(_ fixture: GoogleTransportFixture, at url: URL) { lock.withLock { fixtures[url] = fixture } }
    func record(_ request: URLRequest) -> GoogleTransportFixture? {
        lock.withLock { requests.append(request); return request.url.flatMap { fixtures[$0] } }
    }
    func requests(to url: URL) -> [URLRequest] { lock.withLock { requests.filter { $0.url == url } } }
    func stop(_ url: URL?) { lock.withLock { if let url { stopped.insert(url) } } }
    func didStop(_ url: URL) -> Bool { lock.withLock { stopped.contains(url) } }
}

private final class GoogleTransportURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = GoogleTransportRegistry.shared.record(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        if fixture.hold { return }
        if let error = fixture.error { client?.urlProtocol(self, didFailWithError: error); return }
        if let destination = fixture.redirect {
            let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": destination.absoluteString])!
            var redirected = request
            redirected.url = destination
            // Model the most permissive redirect request handed to the delegate,
            // including an OAuth bearer and a POST body. It must never be sent.
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: fixture.responseURL ?? url, statusCode: fixture.status,
                                       httpVersion: "HTTP/1.1", headerFields: fixture.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { GoogleTransportRegistry.shared.stop(request.url) }
}

private func googleSecurityTransport(configuration: URLSessionConfiguration = .ephemeral) -> URLSessionTransport {
    configuration.protocolClasses = [GoogleTransportURLProtocol.self]
    return URLSessionTransport(configuration: configuration)
}

private func googleSecurityEndpoint() -> URL {
    URL(string: "https://www.googleapis.com/calendar/v3/security-fixture/\(UUID().uuidString)")!
}

private func waitForGoogleRequest(_ condition: @escaping @Sendable () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    return condition()
}

@Test(arguments: [301, 302, 303, 307, 308])
func googleTransportRejectsRedirectsBeforeOAuthBearerOrEventBodyCanLeaveTheEndpoint(_ status: Int) async throws {
    let endpoint = googleSecurityEndpoint()
    let destination = URL(string: "https://\(UUID().uuidString.lowercased()).example.test/redirected")!
    let registry = GoogleTransportRegistry.shared
    registry.install(GoogleTransportFixture(status: status, redirect: destination), at: endpoint)
    registry.install(GoogleTransportFixture(), at: destination)
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("Bearer fixture-google-secret", forHTTPHeaderField: "Authorization")
    request.httpBody = Data(#"{"summary":"Private event body"}"#.utf8)
    await #expect(throws: ProviderError.malformed) { try await googleSecurityTransport().send(request) }
    #expect(registry.requests(to: endpoint).count == 1)
    #expect(registry.requests(to: destination).isEmpty)
}

@Test func googleTransportRejectsSameOriginRedirectAndUnexpectedFinalResponseURL() async throws {
    let endpoint = googleSecurityEndpoint(), destination = googleSecurityEndpoint()
    let registry = GoogleTransportRegistry.shared
    registry.install(GoogleTransportFixture(status: 307, redirect: destination), at: endpoint)
    registry.install(GoogleTransportFixture(), at: destination)
    var request = URLRequest(url: endpoint)
    request.setValue("Bearer fixture-google-secret", forHTTPHeaderField: "Authorization")
    await #expect(throws: ProviderError.malformed) { try await googleSecurityTransport().send(request) }
    #expect(registry.requests(to: destination).isEmpty)
    let unrelated = googleSecurityEndpoint()
    registry.install(GoogleTransportFixture(responseURL: unrelated), at: endpoint)
    await #expect(throws: ProviderError.malformed) { try await googleSecurityTransport().send(request) }
}

@Test func googleTransportDoesNotReuseCookiesBetweenAccountRequests() async throws {
    let first = googleSecurityEndpoint(), second = googleSecurityEndpoint()
    let registry = GoogleTransportRegistry.shared
    registry.install(GoogleTransportFixture(headers: ["Set-Cookie": "fixture_session=private; Secure; Path=/"]), at: first)
    registry.install(GoogleTransportFixture(), at: second)
    let configuration = URLSessionConfiguration.ephemeral
    let cookie = try #require(HTTPCookie(properties: [.domain: "www.googleapis.com", .path: "/", .name: "preexisting", .value: "private", .secure: "TRUE"]))
    configuration.httpCookieStorage?.setCookie(cookie)
    let transport = googleSecurityTransport(configuration: configuration)
    for (url, token) in [(first, "account-a-token"), (second, "account-b-token")] {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try await transport.send(request)
    }
    let firstRequest = try #require(registry.requests(to: first).first)
    let secondRequest = try #require(registry.requests(to: second).first)
    #expect(firstRequest.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(secondRequest.value(forHTTPHeaderField: "Cookie") == nil)
    #expect(firstRequest.value(forHTTPHeaderField: "Authorization") == "Bearer account-a-token")
    #expect(secondRequest.value(forHTTPHeaderField: "Authorization") == "Bearer account-b-token")
}

@Test func googleTransportSanitizesUnderlyingErrorsAndPreservesCancellation() async throws {
    let failing = googleSecurityEndpoint(), held = googleSecurityEndpoint()
    let registry = GoogleTransportRegistry.shared
    registry.install(GoogleTransportFixture(error: URLError(.cannotConnectToHost, userInfo: [NSLocalizedDescriptionKey: "fixture-secret-in-diagnostic"])), at: failing)
    await #expect(throws: ProviderError.network) { try await googleSecurityTransport().send(URLRequest(url: failing)) }
    registry.install(GoogleTransportFixture(hold: true), at: held)
    let task = Task { try await googleSecurityTransport().send(URLRequest(url: held)) }
    #expect(await waitForGoogleRequest { registry.requests(to: held).count == 1 })
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await waitForGoogleRequest { registry.didStop(held) })
}

private actor IsolatedGoogleTokens: AccessTokenSource {
    let values: [AccountID: String]
    var lookups: [(AccountID, Bool)] = []
    init(values: [AccountID: String]) { self.values = values }
    func accessToken(for account: AccountID, forceRefresh: Bool) throws -> String {
        lookups.append((account, forceRefresh))
        guard let token = values[account] else { throw ProviderError.unauthorized }
        return forceRefresh ? token + "-refreshed" : token
    }
}

private actor IsolatedGoogleHTTP: HTTPTransport {
    var requests: [URLRequest] = []
    func send(_ request: URLRequest) -> HTTPResponse {
        requests.append(request)
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer account-a" {
            return HTTPResponse(data: Data(), status: 401)
        }
        return HTTPResponse(data: Data(#"{"id":"event"}"#.utf8), status: 200)
    }
}

@Test func googleTransportRequestsKeepConcurrentAccountsAnd401RefreshesIsolated() async throws {
    let first = AccountID(), second = AccountID()
    let tokens = IsolatedGoogleTokens(values: [first: "account-a", second: "account-b"])
    let http = IsolatedGoogleHTTP()
    let provider = GoogleCalendarProvider(tokens: tokens, transport: http)
    let firstKey = EventKey(calendar: CalendarKey(account: first, calendarID: "account-a-calendar"), eventID: "event")
    let secondKey = EventKey(calendar: CalendarKey(account: second, calendarID: "account-b-calendar"), eventID: "event")
    async let firstEvent = provider.event(firstKey, zone: "UTC")
    async let secondEvent = provider.event(secondKey, zone: "UTC")
    let events = try await [firstEvent, secondEvent]
    #expect(events.map(\.key) == [firstKey, secondKey])
    let requests = await http.requests
    let firstRequests = requests.filter { $0.url?.path.contains("account-a-calendar") == true }
    let secondRequests = requests.filter { $0.url?.path.contains("account-b-calendar") == true }
    #expect(firstRequests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer account-a", "Bearer account-a-refreshed"])
    #expect(secondRequests.map { $0.value(forHTTPHeaderField: "Authorization") } == ["Bearer account-b"])
    let lookups = await tokens.lookups
    #expect(lookups.filter { $0.0 == first }.map(\.1) == [false, true])
    #expect(lookups.filter { $0.0 == second }.map(\.1) == [false])
}
