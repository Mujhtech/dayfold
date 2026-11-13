import Foundation

/// The Google channel identity needed to activate the relay reservation and later
/// stop the watch. Google credentials remain in the local AccessTokenSource.
public struct GoogleWatchChannel: Codable, Equatable, Sendable {
    public var id: UUID
    public var resourceID: String
    public var expiresAt: Date

    public init(id: UUID, resourceID: String, expiresAt: Date) {
        self.id = id
        self.resourceID = resourceID
        self.expiresAt = expiresAt
    }
}

public protocol GoogleCalendarWatching: Sendable {
    func watchEvents(source: CalendarSource, channelID: UUID, token: String, address: URL, expiresAt: Date) async throws -> GoogleWatchChannel
    func watchCalendarList(account: AccountID, channelID: UUID, token: String, address: URL, expiresAt: Date) async throws -> GoogleWatchChannel
    func stopChannel(account: AccountID, channelID: UUID, resourceID: String) async throws
}

extension GoogleCalendarProvider: GoogleCalendarWatching {
    /// Persist the reservation before calling. A transport error, server error,
    /// or malformed success can mean Google created the watch: retain that pending
    /// identity until reconciliation or expiration instead of creating new IDs.
    public func watchEvents(source: CalendarSource, channelID: UUID, token: String, address: URL, expiresAt: Date) async throws -> GoogleWatchChannel {
        guard !source.key.calendarID.isEmpty else { throw ProviderError.invalid }
        // events.watch also accepts calendar.events.freebusy. A limited source
        // can receive change hints while its subsequent fetch remains redacted.
        guard source.readable || (!source.deleted && source.freeBusyOnly) else { throw ProviderError.forbidden }
        return try await watch(account: source.key.account, path: ["calendars", source.key.calendarID, "events", "watch"], channelID: channelID, token: token, address: address, expiresAt: expiresAt)
    }

    public func watchCalendarList(account: AccountID, channelID: UUID, token: String, address: URL, expiresAt: Date) async throws -> GoogleWatchChannel {
        try await watch(account: account, path: ["users", "me", "calendarList", "watch"], channelID: channelID, token: token, address: address, expiresAt: expiresAt)
    }

    public func stopChannel(account: AccountID, channelID: UUID, resourceID: String) async throws {
        guard Self.validWatchResourceID(resourceID) else { throw ProviderError.invalid }
        do {
            _ = try await request(account: account, path: ["channels", "stop"], method: "POST", body: [
                "id": .string(channelID.uuidString.lowercased()),
                "resourceId": .string(resourceID)
            ])
        } catch ProviderError.missing {
            // Expired or already stopped channels need no further cleanup.
        } catch ProviderError.expiredCursor {
            // The shared Google error classifier maps HTTP 410 to this case.
        }
    }

    private func watch(account: AccountID, path: [String], channelID: UUID, token: String, address: URL, expiresAt: Date) async throws -> GoogleWatchChannel {
        guard let components = URLComponents(url: address, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil, components.password == nil, components.fragment == nil,
              !token.isEmpty, token.utf8.count <= 256,
              token.utf8.allSatisfy({ (0x21...0x7e).contains($0) }) else { throw ProviderError.invalid }
        let milliseconds = expiresAt.timeIntervalSince1970 * 1_000
        guard milliseconds.isFinite, milliseconds > Date().timeIntervalSince1970 * 1_000,
              milliseconds < Double(Int64.max) else { throw ProviderError.invalid }
        let requestedExpiration = Int64(milliseconds.rounded(.down))
        let raw = try await request(account: account, path: path, method: "POST", body: [
            "id": .string(channelID.uuidString.lowercased()),
            "type": .string("web_hook"),
            "token": .string(token),
            "address": .string(address.absoluteString),
            // Google int64 fields use decimal strings; expiration is Unix ms.
            "expiration": .string(String(requestedExpiration))
        ])
        guard raw.text("kind") == "api#channel",
              let returnedID = raw["id"]?.string.flatMap(UUID.init(uuidString:)), returnedID == channelID,
              let resourceID = raw["resourceId"]?.string, Self.validWatchResourceID(resourceID),
              let expiration = Self.watchExpiration(raw["expiration"]),
              expiration <= requestedExpiration,
              raw["token"] == nil || raw["token"] == .string(token) else { throw ProviderError.malformed }
        let actualExpiration = Date(timeIntervalSince1970: Double(expiration) / 1_000)
        guard actualExpiration > Date() else { throw ProviderError.malformed }
        return GoogleWatchChannel(id: returnedID, resourceID: resourceID, expiresAt: actualExpiration)
    }

    private static func watchExpiration(_ value: JSONValue?) -> Int64? {
        if let string = value?.string {
            guard !string.isEmpty, string.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
                  let milliseconds = Int64(string), milliseconds > 0 else { return nil }
            return milliseconds
        }
        if let number = value?.number {
            // Above 2^53 JSONValue's Double would lose the exact integer value.
            guard number.isFinite, number > 0, number <= 9_007_199_254_740_991,
                  number.rounded(.down) == number else { return nil }
            return Int64(number)
        }
        return nil
    }

    private static func validWatchResourceID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= 512
            && value.utf8.allSatisfy { (0x20...0x7e).contains($0) }
    }
}
