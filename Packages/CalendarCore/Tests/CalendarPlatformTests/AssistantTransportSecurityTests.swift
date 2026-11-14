import Foundation
import Testing
@testable import CalendarPlatform

private struct AssistantNetworkFixture: Sendable {
    var status = 200
    var redirect: URL?
    var body = Data("{}".utf8)
    var advertisedSize: Int?
    var hold = false
}

private final class AssistantNetworkRegistry: @unchecked Sendable {
    static let shared = AssistantNetworkRegistry()
    private let lock = NSLock()
    private var fixtures: [String: AssistantNetworkFixture] = [:]
    private var requests: [String: [URLRequest]] = [:]
    private var stopped: Set<String> = []
    func install(_ fixture: AssistantNetworkFixture, id: String) { lock.withLock { fixtures[id] = fixture } }
    func record(_ request: URLRequest) -> AssistantNetworkFixture? {
        lock.withLock {
            let id = request.value(forHTTPHeaderField: "X-Dayfold-Fixture") ?? ""
            requests[id, default: []].append(request)
            return fixtures[id]
        }
    }
    func allRequests(_ id: String) -> [URLRequest] { lock.withLock { requests[id] ?? [] } }
    func didStop(_ id: String) { lock.withLock { _ = stopped.insert(id) } }
    func hasStopped(_ id: String) -> Bool { lock.withLock { stopped.contains(id) } }
}

private final class AssistantFixtureURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = AssistantNetworkRegistry.shared.record(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        if fixture.hold { return }
        if let target = fixture.redirect {
            let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString])!
            var redirected = request; redirected.url = target
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        var headers = ["Content-Type": "application/json"]
        let size = fixture.advertisedSize ?? fixture.body.count
        if size >= 0 { headers["Content-Length"] = String(size) }
        let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        AssistantNetworkRegistry.shared.didStop(request.value(forHTTPHeaderField: "X-Dayfold-Fixture") ?? "")
    }
}

private func assistantNetworkRequest(_ fixture: AssistantNetworkFixture) -> (OpenAIResponsesTransport, URLRequest, String) {
    let id = UUID().uuidString
    AssistantNetworkRegistry.shared.install(fixture, id: id)
    let transport = OpenAIResponsesTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AssistantFixtureURLProtocol.self]
        return configuration
    }
    var request = URLRequest(url: OpenAIResponsesTransport.endpoint)
    request.httpMethod = "POST"
    request.setValue(id, forHTTPHeaderField: "X-Dayfold-Fixture")
    request.setValue("Bearer fixture-private-key", forHTTPHeaderField: "Authorization")
    request.httpBody = Data("{}".utf8)
    return (transport, request, id)
}

@Test(arguments: [301, 302, 307, 308])
func assistantTransportNeverForwardsKeysAcrossRedirects(_ status: Int) async throws {
    let destination = URL(string: "https://untrusted.example.test/stolen")!
    let (transport, request, id) = assistantNetworkRequest(.init(status: status, redirect: destination))
    await #expect(throws: AssistantRequestFailure.redirected) { try await transport.send(request) }
    let requests = AssistantNetworkRegistry.shared.allRequests(id)
    #expect(requests.count == 1)
    #expect(requests.allSatisfy { $0.url == OpenAIResponsesTransport.endpoint })
}

@Test func assistantTransportRejectsAnyOtherEndpointBeforeSending() async throws {
    let (transport, original, id) = assistantNetworkRequest(.init())
    var request = original; request.url = URL(string: "https://api.openai.com/v1/responses?other=1")!
    await #expect(throws: AssistantRequestFailure.redirected) { try await transport.send(request) }
    #expect(AssistantNetworkRegistry.shared.allRequests(id).isEmpty)
}

@Test func assistantTransportLimitsAdvertisedAndActualResponseBytes() async throws {
    let limit = OpenAIResponsesTransport.maximumResponseBytes
    let (advertised, first, _) = assistantNetworkRequest(.init(advertisedSize: limit + 1))
    await #expect(throws: AssistantRequestFailure.oversized) { try await advertised.send(first) }
    let (streamed, second, _) = assistantNetworkRequest(.init(body: Data(repeating: 65, count: limit + 1), advertisedSize: -1))
    await #expect(throws: AssistantRequestFailure.oversized) { try await streamed.send(second) }
}

@Test func assistantTransportCancellationStopsTheURLSessionTask() async throws {
    let (transport, request, id) = assistantNetworkRequest(.init(hold: true))
    let task = Task { try await transport.send(request) }
    while AssistantNetworkRegistry.shared.allRequests(id).isEmpty { await Task.yield() }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    while !AssistantNetworkRegistry.shared.hasStopped(id) { await Task.yield() }
    #expect(AssistantNetworkRegistry.shared.allRequests(id).count == 1)
}

@Test func assistantTransportDisablesPersistentCredentialCookieAndResponseStorage() {
    let original = URLSessionConfiguration.ephemeral
    original.httpShouldSetCookies = true
    original.httpCookieAcceptPolicy = .always
    let session = OpenAIResponsesTransport.makeSession(configuration: original, delegate: AssistantRedirectPolicy())
    defer { session.invalidateAndCancel() }
    let actual = session.configuration
    #expect(actual.urlCache == nil && actual.urlCredentialStorage == nil && actual.httpCookieStorage == nil)
    #expect(!actual.httpShouldSetCookies && actual.httpCookieAcceptPolicy == .never)
    #expect(actual.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(original.httpShouldSetCookies && original.httpCookieAcceptPolicy == .always)
}
