import Foundation

public enum RelayNotificationKind: String, Codable, Sendable {
    case calendarChanged = "calendar_changed"
    case reminderDue = "reminder_due"
}

public enum RelayPushEnvironment: String, Codable, Sendable {
    case sandbox, production
}

public struct RelayNotification: Codable, Sendable, Equatable {
    public var sequence: Int64
    public var id: UUID
    public var kind: RelayNotificationKind
    public var subjectID: UUID
    public var revision: Int64?
    public var createdAt: Date
    public var expiresAt: Date

    public init(sequence: Int64, id: UUID, kind: RelayNotificationKind, subjectID: UUID,
                revision: Int64?, createdAt: Date, expiresAt: Date) {
        self.sequence = sequence; self.id = id; self.kind = kind; self.subjectID = subjectID
        self.revision = revision; self.createdAt = createdAt; self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey {
        case sequence, id, kind, revision
        case subjectID = "subject_id", createdAt = "created_at", expiresAt = "expires_at"
    }

    func validate() throws {
        guard sequence > 0, expiresAt > createdAt else { throw RelayClientError.invalidResponse }
        switch kind {
        case .calendarChanged: guard revision == nil else { throw RelayClientError.invalidResponse }
        case .reminderDue: guard let revision, revision > 0 else { throw RelayClientError.invalidResponse }
        }
    }
}

public struct RelayChannelReservation: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var id: UUID
    public var token: String
    public var address: URL
    public var expiresAt: Date

    public init(id: UUID, token: String, address: URL, expiresAt: Date) {
        self.id = id; self.token = token; self.address = address; self.expiresAt = expiresAt
    }

    enum CodingKeys: String, CodingKey { case id, token, address; case expiresAt = "expires_at" }
    public var description: String { "RelayChannelReservation(id: \(id), token: [REDACTED])" }
    public var debugDescription: String { description }
}

public struct RelayNotificationPage: Codable, Sendable, Equatable {
    public var notifications: [RelayNotification]
    public var cursorFloor: Int64
    public var latestSequence: Int64

    public init(notifications: [RelayNotification], cursorFloor: Int64, latestSequence: Int64) {
        self.notifications = notifications; self.cursorFloor = cursorFloor; self.latestSequence = latestSequence
    }

    enum CodingKeys: String, CodingKey {
        case notifications; case cursorFloor = "cursor_floor", latestSequence = "latest_sequence"
    }
}

public struct RelayCursor: Codable, Sendable, Equatable {
    public var floor: Int64
    public var current: Int64
    public init(floor: Int64, current: Int64) { self.floor = floor; self.current = current }
}

public struct RelayCapabilities: Codable, Sendable, Equatable {
    public var apnsEnabled: Bool
    public init(apnsEnabled: Bool) { self.apnsEnabled = apnsEnabled }
    enum CodingKeys: String, CodingKey { case apnsEnabled = "apns_enabled" }
}

public enum RelayStreamEvent: Sendable, Equatable {
    case notification(RelayNotification)
    case resyncRequired
}

/// Errors deliberately contain no response bodies, tokens, request headers or URLs.
public enum RelayClientError: Error, Sendable, Equatable, LocalizedError {
    case invalidConfiguration
    case invalidRequest
    case unauthorized
    case credentialsUnavailable
    case authenticationInProgress
    case reauthenticationRequired
    case sessionSuperseded
    case identityMismatch
    case resyncRequired
    case rateLimited(retryAfter: TimeInterval?)
    case unavailable(retryAfter: TimeInterval?)
    case rejected(status: Int)
    case invalidResponse
    case streamOverflow
    case transport
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The notification service address or credential is invalid."
        case .invalidRequest: "The notification request is invalid."
        case .unauthorized: "The notification service credential was rejected."
        case .credentialsUnavailable: "Unlock your Mac to access your Dayfold session, then retry."
        case .authenticationInProgress: "Finish or cancel Dayfold sign-in to resume real-time updates."
        case .reauthenticationRequired: "Your Dayfold session ended. Sign in again to reconnect this Mac."
        case .sessionSuperseded: "Your Dayfold session changed. Sign in again to recover this Mac."
        case .identityMismatch: "Choose the same Dayfold account, or sign out before switching accounts."
        case .resyncRequired: "The notification history requires reconciliation."
        case .rateLimited: "The notification service asked the app to wait."
        case .unavailable: "The notification service is temporarily unavailable."
        case .rejected(let status): "The notification service rejected the request (\(status))."
        case .invalidResponse: "The notification service returned an invalid response."
        case .streamOverflow: "The notification stream needs to reconnect and replay."
        case .transport: "The notification service could not be reached."
        case .cancelled: "The notification request was cancelled."
        }
    }
}

public enum RelayEndpoint {
    /// Accepts an origin, never an arbitrary request URL. Loopback HTTP requires
    /// an explicit development opt-in by the caller.
    public static func validatedOrigin(_ url: URL, allowLoopbackHTTP: Bool = false) throws -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/",
              parts.port.map({ (1...65_535).contains($0) }) ?? true else {
            throw RelayClientError.invalidConfiguration
        }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (allowLoopbackHTTP && scheme == "http" && loopback) else {
            throw RelayClientError.invalidConfiguration
        }
        parts.scheme = scheme; parts.host = host; parts.path = "/"
        guard let normalized = parts.url else { throw RelayClientError.invalidConfiguration }
        return normalized
    }

    public static func validateToken(_ token: String) throws {
        guard token.utf8.count == 64, token.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { throw RelayClientError.invalidConfiguration }
    }
}

public protocol RelayClientProtocol: Sendable {
    func capabilities() async throws -> RelayCapabilities
    func cursor() async throws -> RelayCursor
    func notifications(after: Int64) async throws -> RelayNotificationPage
    func acknowledge(sequence: Int64) async throws
    func claimReminder(notificationID: UUID) async throws -> Bool
    func reserveChannel(scopeID: UUID, expiresAt: Date) async throws -> RelayChannelReservation
    func activateChannel(id: UUID, resourceID: String, expiresAt: Date) async throws
    func revokeChannel(id: UUID) async throws
    func putReminder(id: UUID, revision: Int64, dueAt: Date, expiresAt: Date) async throws
    func deleteReminder(id: UUID, revision: Int64) async throws
    func registerPush(token: String, environment: RelayPushEnvironment) async throws
    func revokeDevice() async throws
    func events(after: Int64) -> AsyncThrowingStream<RelayStreamEvent, Error>
}

public struct RelayHTTPHead: Sendable {
    public var url: URL
    public var status: Int
    public var headers: [String: String]
    public init(url: URL, status: Int, headers: [String: String] = [:]) {
        self.url = url; self.status = status; self.headers = headers
    }
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct RelayHTTPResponse: Sendable {
    public var head: RelayHTTPHead
    public var body: Data
    public init(head: RelayHTTPHead, body: Data = Data()) { self.head = head; self.body = body }
}

public enum RelayTransportEvent: Sendable {
    case response(RelayHTTPHead)
    case data(Data)
}

public struct RelayTransportStream: Sendable {
    public let events: AsyncThrowingStream<RelayTransportEvent, Error>
    public let cancel: @Sendable () -> Void
    public init(events: AsyncThrowingStream<RelayTransportEvent, Error>, cancel: @escaping @Sendable () -> Void) {
        self.events = events; self.cancel = cancel
    }
}

/// Inject trusted fixtures or another transport that obeys the no-redirect and
/// cancellation contract. The production implementation is URLSession-backed.
public protocol RelayTransport: Sendable {
    func send(_ request: URLRequest) async throws -> RelayHTTPResponse
    func stream(_ request: URLRequest) -> RelayTransportStream
}

enum RelayJSON {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseInternetDate(value) else { throw RelayClientError.invalidResponse }
            return date
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var value = encoder.singleValueContainer()
            try value.encode(formatter.string(from: date))
        }
        return encoder
    }

    static func parseInternetDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
