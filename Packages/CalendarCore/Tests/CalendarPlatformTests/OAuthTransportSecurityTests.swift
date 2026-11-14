import Foundation
import Testing
@testable import CalendarPlatform

private struct OAuthRedirectFixture: Sendable {
    var status = 200
    var redirect: URL?
}

private final class OAuthRedirectRegistry: @unchecked Sendable {
    static let shared = OAuthRedirectRegistry()
    private let lock = NSLock()
    private var fixtures: [URL: OAuthRedirectFixture] = [:]
    private var requests: [URLRequest] = []
    func install(_ fixture: OAuthRedirectFixture, at url: URL) { lock.withLock { fixtures[url] = fixture } }
    func record(_ request: URLRequest) -> OAuthRedirectFixture? {
        lock.withLock { requests.append(request); return request.url.flatMap { fixtures[$0] } }
    }
    func requests(to url: URL) -> [URLRequest] { lock.withLock { requests.filter { $0.url == url } } }
}

private final class OAuthRedirectURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let fixture = OAuthRedirectRegistry.shared.record(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        if let destination = fixture.redirect {
            let response = HTTPURLResponse(url: url, statusCode: fixture.status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": destination.absoluteString])!
            var redirected = request
            redirected.url = destination
            client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test(arguments: [307, 308])
func oauthTransportNeverForwardsRefreshTokenPOSTToRedirectDestination(_ status: Int) async throws {
    let endpoint = URL(string: "https://oauth2.googleapis.com/token?fixture=\(UUID().uuidString)")!
    let destination = URL(string: "https://\(UUID().uuidString.lowercased()).example.test/stolen")!
    let registry = OAuthRedirectRegistry.shared
    registry.install(OAuthRedirectFixture(status: status, redirect: destination), at: endpoint)
    registry.install(OAuthRedirectFixture(), at: destination)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [OAuthRedirectURLProtocol.self]
    let session = OAuthTokenTransport.makeSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data("grant_type=refresh_token&refresh_token=fixture-private-refresh&client_id=fixture-client".utf8)
    do {
        _ = try await session.data(for: request)
        Issue.record("token endpoint redirect should fail before a second request")
    } catch {
        #expect((error as? URLError)?.code == .cancelled)
    }
    #expect(registry.requests(to: endpoint).count == 1)
    #expect(registry.requests(to: destination).isEmpty)
}

@Test func oauthTransportDisablesCookieCredentialAndResponseStorage() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = true
    configuration.httpCookieAcceptPolicy = .always
    configuration.requestCachePolicy = .returnCacheDataElseLoad
    let session = OAuthTokenTransport.makeSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let actual = session.configuration
    #expect(actual.httpCookieStorage == nil)
    #expect(actual.urlCredentialStorage == nil)
    #expect(actual.urlCache == nil)
    #expect(!actual.httpShouldSetCookies)
    #expect(actual.httpCookieAcceptPolicy == .never)
    #expect(actual.requestCachePolicy == .reloadIgnoringLocalCacheData)
    #expect(configuration.httpShouldSetCookies)
    #expect(configuration.httpCookieAcceptPolicy == .always)
}
