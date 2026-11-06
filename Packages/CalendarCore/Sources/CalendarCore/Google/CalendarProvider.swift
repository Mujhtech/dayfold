import Foundation

public struct ProviderPage<T: Sendable>: Sendable {
    public var items: [T]
    public var nextPage: String?
    public var syncToken: String?
    public init(items: [T], nextPage: String? = nil, syncToken: String? = nil) { self.items = items; self.nextPage = nextPage; self.syncToken = syncToken }
}
public enum EventQuery: Sendable, Equatable {
    case resources(syncToken: String?)
    case occurrences(DateInterval)
    public static let fingerprint = "resource-v1:singleEvents=false;showDeleted=true;showHiddenInvitations=true;maxResults=1000"
    public var parameters: [String: String] {
        switch self {
        case .resources(let token):
            var p = ["singleEvents": "false", "showDeleted": "true", "showHiddenInvitations": "true", "maxResults": "1000"]
            p["syncToken"] = token; return p
        case .occurrences(let window):
            return ["singleEvents": "true", "showDeleted": "false", "orderBy": "startTime", "maxResults": "1000", "timeMin": InternetDate.string(window.start), "timeMax": InternetDate.string(window.end)]
        }
    }
}
public protocol CalendarProvider: Sendable {
    func calendars(account: AccountID, page: String?) async throws -> ProviderPage<CalendarSource>
    func events(source: CalendarSource, query: EventQuery, page: String?) async throws -> ProviderPage<CalendarEvent>
    func event(_ key: EventKey, zone: String) async throws -> CalendarEvent
    func write(_ mutation: Mutation, etag: String?, zone: String) async throws -> CalendarEvent?
    func busy(source: CalendarSource, window: DateInterval) async throws -> [CalendarEvent]
}
public enum ProviderError: Error, LocalizedError, Equatable, Sendable {
    case invalid, unauthorized, credentialsUnavailable, forbidden, organization, missing, duplicate, expiredCursor, conflict, throttled(TimeInterval?), server, network, malformed
    public var errorDescription: String? {
        switch self {
        case .invalid: "Google could not accept these event details. Review the draft."
        case .unauthorized: "This account needs you to sign in again."
        case .credentialsUnavailable: "Keychain is unavailable. Unlock your Mac and retry; existing credentials have been retained."
        case .forbidden: "Google no longer allows this action. Refresh the calendar's permissions."
        case .organization: "Your organization has blocked access. Contact your Workspace administrator."
        case .missing: "This event is unavailable, or access has changed."
        case .duplicate: "Checking the event already saved in Google."
        case .expiredCursor: "Refreshing this calendar's cache."
        case .conflict: "Google changed this event while you were editing it."
        case .throttled: "Google asked this account to wait before trying again."
        case .server: "Google is temporarily unavailable."
        case .network: "Waiting for a connection. Your local changes are safe."
        case .malformed: "Google returned an unreadable response. The existing cache has been preserved."
        }
    }
    public var category: String {
        switch self { case .invalid: "invalid"; case .unauthorized: "authorization"; case .credentialsUnavailable: "credentials"; case .forbidden: "permission"; case .organization: "organization"; case .missing: "missing"; case .duplicate: "duplicate"; case .expiredCursor: "cursor"; case .conflict: "conflict"; case .throttled: "throttled"; case .server: "server"; case .network: "offline"; case .malformed: "malformed" }
    }
    public static func classify(status: Int, reason: String, retryAfter: String?) -> Self {
        switch status {
        case 400: .invalid; case 401: .unauthorized
        case 403 where ["rateLimitExceeded", "userRateLimitExceeded", "quotaExceeded"].contains(reason): .throttled(retryAfter.flatMap(Double.init))
        case 403 where ["domainPolicy", "admin_policy_enforced"].contains(reason): .organization
        case 403: .forbidden; case 404: .missing; case 409: .duplicate; case 410: .expiredCursor; case 412: .conflict
        case 429: .throttled(retryAfter.flatMap(Double.init)); case 500...599: .server; default: .malformed
        }
    }
}
public protocol AccessTokenSource: Sendable { func accessToken(for account: AccountID, forceRefresh: Bool) async throws -> String }
public struct HTTPResponse: Sendable { public var data: Data; public var status: Int; public var retryAfter: String?; public init(data: Data, status: Int, retryAfter: String? = nil) { self.data = data; self.status = status; self.retryAfter = retryAfter } }
public protocol HTTPTransport: Sendable { func send(_ request: URLRequest) async throws -> HTTPResponse }
public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession
    public init() {
        let c = URLSessionConfiguration.ephemeral; c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 90
        session = URLSession(configuration: c)
    }
    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, data.count <= 32_000_000 else { throw ProviderError.malformed }
            return HTTPResponse(data: data, status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
        } catch is CancellationError { throw CancellationError() }
        catch let e as ProviderError { throw e }
        catch { throw ProviderError.network }
    }
}
