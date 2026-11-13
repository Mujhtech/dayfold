import Foundation
import Testing
@testable import CalendarCore

private actor WatchTokens: AccessTokenSource {
    var accounts: [AccountID] = []
    var forced: [Bool] = []
    func accessToken(for account: AccountID, forceRefresh: Bool) -> String {
        accounts.append(account); forced.append(forceRefresh)
        return forceRefresh ? "refreshed-local-token" : "cached-local-token"
    }
}

private actor WatchHTTP: HTTPTransport {
    var script: [Result<HTTPResponse, ProviderError>]
    var requests: [URLRequest] = []
    init(_ script: [Result<HTTPResponse, ProviderError>]) { self.script = script }
    func send(_ request: URLRequest) throws -> HTTPResponse {
        requests.append(request)
        guard !script.isEmpty else { throw ProviderError.network }
        return try script.removeFirst().get()
    }
}

private let watchAddress = URL(string: "https://relay.example.com/v1/google/webhook")!

private func watchJSON(id: UUID, expiresAt: Date, numeric: Bool = false) -> JSONObject {
    let milliseconds = Int64((expiresAt.timeIntervalSince1970 * 1_000).rounded(.down))
    return ["kind": .string("api#channel"), "id": .string(id.uuidString.lowercased()),
            "resourceId": .string("opaque-resource"),
            "expiration": numeric ? .number(Double(milliseconds)) : .string(String(milliseconds))]
}

private func watchResponse(_ json: JSONObject, status: Int = 200) throws -> Result<HTTPResponse, ProviderError> {
    .success(HTTPResponse(data: try JSONEncoder().encode(json), status: status))
}

@Test func googleWatchEventsUsesLocalAuthorizationAndEncodedCalendarPath() async throws {
    let account = AccountID(), channel = UUID(), tokens = WatchTokens()
    let source = CalendarSource(key: CalendarKey(account: account, calendarID: "a/b+#?@example.com"), title: "Private calendar title", role: "reader")
    let requested = Date().addingTimeInterval(3_600), actual = Date().addingTimeInterval(1_800)
    let http = WatchHTTP(try [watchResponse(watchJSON(id: channel, expiresAt: actual))])
    let provider = GoogleCalendarProvider(tokens: tokens, transport: http)
    let result = try await provider.watchEvents(source: source, channelID: channel, token: "opaque-channel-secret", address: watchAddress, expiresAt: requested)
    let request = try #require(await http.requests.first)
    #expect(request.httpMethod == "POST")
    let url = try #require(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
    #expect(url.scheme == "https" && url.host == "www.googleapis.com")
    #expect(url.percentEncodedPath == "/calendar/v3/calendars/a%2Fb%2B%23%3F%40example.com/events/watch")
    #expect(url.queryItems?.isEmpty != false)
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cached-local-token")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
    let body = try JSONDecoder().decode(JSONObject.self, from: #require(request.httpBody))
    #expect(body == ["id": .string(channel.uuidString.lowercased()), "type": .string("web_hook"),
                     "token": .string("opaque-channel-secret"), "address": .string(watchAddress.absoluteString),
                     "expiration": .string(String(Int64((requested.timeIntervalSince1970 * 1_000).rounded(.down))))])
    #expect(result.id == channel && result.resourceID == "opaque-resource")
    #expect(result.expiresAt <= requested && abs(result.expiresAt.timeIntervalSince(actual)) < 0.0011)
    #expect(await tokens.accounts == [account])
    #expect(await tokens.forced == [false])
}

@Test func googleWatchCalendarListAcceptsNumericExpiration() async throws {
    let account = AccountID(), channel = UUID(), expiration = Date().addingTimeInterval(3_600)
    let http = WatchHTTP(try [watchResponse(watchJSON(id: channel, expiresAt: expiration, numeric: true))])
    let provider = GoogleCalendarProvider(tokens: WatchTokens(), transport: http)
    let result = try await provider.watchCalendarList(account: account, channelID: channel, token: "opaque-secret", address: watchAddress, expiresAt: expiration)
    #expect(result.id == channel)
    #expect(await http.requests.first?.url?.path == "/calendar/v3/users/me/calendarList/watch")
}

@Test func googleWatchAllowsFreeBusyHintsAndPreservesPartialAuthorizationErrors() async throws {
    let source = CalendarSource(key: CalendarKey(account: AccountID(), calendarID: "limited"), title: "Availability", role: "freeBusyReader")
    let channel = UUID(), expires = Date().addingTimeInterval(3_600), tokens = WatchTokens()
    let http = WatchHTTP(try [watchResponse(watchJSON(id: channel, expiresAt: expires)), watchResponse([:], status: 403)])
    let provider = GoogleCalendarProvider(tokens: tokens, transport: http)
    _ = try await provider.watchEvents(source: source, channelID: channel, token: "opaque-secret", address: watchAddress, expiresAt: expires)
    await #expect(throws: ProviderError.forbidden) {
        try await provider.watchCalendarList(account: source.key.account, channelID: UUID(), token: "opaque-secret", address: watchAddress, expiresAt: expires)
    }
    #expect(await tokens.forced == [false, false])
    #expect(await http.requests.count == 2)
    var deleted = source; deleted.deleted = true
    await #expect(throws: ProviderError.forbidden) {
        try await provider.watchEvents(source: deleted, channelID: UUID(), token: "opaque-secret", address: watchAddress, expiresAt: expires)
    }
    #expect(await http.requests.count == 2)
}

@Test func googleWatchRetriesOnlyOneRejectedAuthorizationWithTheSameReservation() async throws {
    let channel = UUID(), account = AccountID(), expires = Date().addingTimeInterval(3_600), tokens = WatchTokens()
    let http = WatchHTTP(try [watchResponse([:], status: 401), watchResponse(watchJSON(id: channel, expiresAt: expires))])
    let provider = GoogleCalendarProvider(tokens: tokens, transport: http)
    _ = try await provider.watchCalendarList(account: account, channelID: channel, token: "opaque-secret", address: watchAddress, expiresAt: expires)
    let requests = await http.requests
    #expect(requests.count == 2)
    let firstBody = try JSONDecoder().decode(JSONObject.self, from: #require(requests[0].httpBody))
    let retryBody = try JSONDecoder().decode(JSONObject.self, from: #require(requests[1].httpBody))
    #expect(firstBody == retryBody)
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer refreshed-local-token")
    #expect(await tokens.forced == [false, true])
    let rejected = WatchHTTP(try [watchResponse([:], status: 401), watchResponse([:], status: 401)])
    await #expect(throws: ProviderError.unauthorized) {
        try await GoogleCalendarProvider(tokens: WatchTokens(), transport: rejected).watchCalendarList(account: account, channelID: UUID(), token: "opaque-secret", address: watchAddress, expiresAt: expires)
    }
    #expect(await rejected.requests.count == 2)
}

@Test(arguments: [ProviderError.network, .server])
func googleWatchAmbiguousCreationIsNotAutomaticallyRetried(_ failure: ProviderError) async throws {
    let channel = UUID(), expires = Date().addingTimeInterval(3_600)
    let first: Result<HTTPResponse, ProviderError> = failure == .network ? .failure(.network) : .success(HTTPResponse(data: Data(), status: 503))
    let http = WatchHTTP(try [first, watchResponse(watchJSON(id: channel, expiresAt: expires))])
    await #expect(throws: failure) {
        try await GoogleCalendarProvider(tokens: WatchTokens(), transport: http).watchCalendarList(account: AccountID(), channelID: channel, token: "opaque-secret", address: watchAddress, expiresAt: expires)
    }
    #expect(await http.requests.count == 1)
}

@Test(arguments: ["wrong-id", "empty-resource", "control-resource", "missing-expiration", "late-expiration", "expired", "fractional", "overflow", "wrong-kind", "wrong-token"])
func googleWatchRejectsUnboundOrUnboundedResponses(_ invalid: String) async throws {
    let channel = UUID(), expires = Date().addingTimeInterval(3_600)
    var raw = watchJSON(id: channel, expiresAt: expires)
    switch invalid {
    case "wrong-id": raw["id"] = .string(UUID().uuidString)
    case "empty-resource": raw["resourceId"] = .string("")
    case "control-resource": raw["resourceId"] = .string("resource\nother")
    case "missing-expiration": raw.removeValue(forKey: "expiration")
    case "late-expiration": raw["expiration"] = .string(String(Int64(expires.timeIntervalSince1970 * 1_000) + 1))
    case "expired": raw["expiration"] = .string("1")
    case "fractional": raw["expiration"] = .number(Double(Int64(expires.timeIntervalSince1970 * 1_000)) + 0.5)
    case "overflow": raw["expiration"] = .string("9223372036854775808")
    case "wrong-kind": raw["kind"] = .string("calendar#events")
    case "wrong-token": raw["token"] = .string("different-secret")
    default: break
    }
    let http = WatchHTTP(try [watchResponse(raw)])
    await #expect(throws: ProviderError.malformed) {
        try await GoogleCalendarProvider(tokens: WatchTokens(), transport: http).watchCalendarList(account: AccountID(), channelID: channel, token: "opaque-secret", address: watchAddress, expiresAt: expires)
    }
    #expect(await http.requests.count == 1)
}

@Test func googleWatchRejectsInvalidCallbackInputsBeforeUsingCredentials() async throws {
    let tokens = WatchTokens(), http = WatchHTTP([]), expires = Date().addingTimeInterval(3_600)
    let provider = GoogleCalendarProvider(tokens: tokens, transport: http)
    let inputs: [(String, URL, Date)] = [
        ("", watchAddress, expires), (String(repeating: "s", count: 257), watchAddress, expires),
        ("secret\r\nvalue", watchAddress, expires),
        ("opaque", URL(string: "http://relay.example.com/callback")!, expires),
        ("opaque", URL(string: "https://user:password@relay.example.com/callback")!, expires),
        ("opaque", URL(string: "https://relay.example.com/callback#fragment")!, expires),
        ("opaque", watchAddress, .distantPast),
        ("opaque", watchAddress, Date(timeIntervalSince1970: .nan))
    ]
    for (token, address, expiration) in inputs {
        await #expect(throws: ProviderError.invalid) {
            try await provider.watchCalendarList(account: AccountID(), channelID: UUID(), token: token, address: address, expiresAt: expiration)
        }
    }
    #expect(await tokens.forced.isEmpty)
    #expect(await http.requests.isEmpty)
}

@Test func googleWatchStopAcceptsEmptySuccessAndAlreadyGoneChannels() async throws {
    let account = AccountID(), channel = UUID(), tokens = WatchTokens()
    let http = WatchHTTP([204, 404, 410, 403].map { .success(HTTPResponse(data: Data(), status: $0)) })
    let provider = GoogleCalendarProvider(tokens: tokens, transport: http)
    for _ in 0..<3 { try await provider.stopChannel(account: account, channelID: channel, resourceID: "opaque-resource") }
    await #expect(throws: ProviderError.forbidden) {
        try await provider.stopChannel(account: account, channelID: channel, resourceID: "opaque-resource")
    }
    for request in await http.requests {
        #expect(request.httpMethod == "POST" && request.url?.path == "/calendar/v3/channels/stop")
        let body = try JSONDecoder().decode(JSONObject.self, from: #require(request.httpBody))
        #expect(body == ["id": .string(channel.uuidString.lowercased()), "resourceId": .string("opaque-resource")])
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer cached-local-token")
    }
    #expect(await tokens.accounts == Array(repeating: account, count: 4))
}
