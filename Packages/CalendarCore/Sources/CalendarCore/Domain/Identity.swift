import Foundation

public struct AccountID: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
    public let rawValue: String
    public var id: String { rawValue }
    public init(rawValue: String = UUID().uuidString.lowercased()) { self.rawValue = rawValue }
}

public struct CalendarKey: Hashable, Codable, Sendable, Identifiable {
    public let account: AccountID
    public let calendarID: String
    public init(account: AccountID, calendarID: String) { self.account = account; self.calendarID = calendarID }
    public var id: String { account.rawValue + ":" + Data(calendarID.utf8).base64EncodedString() }
}

public struct EventKey: Hashable, Codable, Sendable, Identifiable {
    public let calendar: CalendarKey
    public let eventID: String
    public init(calendar: CalendarKey, eventID: String) { self.calendar = calendar; self.eventID = eventID }
    public var id: String { calendar.id + ":" + Data(eventID.utf8).base64EncodedString() }
}

public enum AccountStatus: String, Codable, CaseIterable, Sendable {
    case connecting, discovering, loading, healthy, offline, refreshing, needsReconnection, keychainUnavailable, blockedByOrganization, throttled, removing
    public var label: String {
        switch self {
        case .connecting: "Connecting"; case .discovering: "Finding calendars"; case .loading: "Loading calendars"
        case .healthy: "Up to date"; case .offline: "Offline"; case .refreshing: "Refreshing sign-in"
        case .needsReconnection: "Sign in again"; case .blockedByOrganization: "Blocked by organization"
        case .keychainUnavailable: "Unlock your Mac to sync"
        case .throttled: "Waiting to retry"; case .removing: "Disconnecting"
        }
    }
}

public struct CalendarAccount: Identifiable, Codable, Equatable, Sendable {
    public var id: AccountID
    public var issuer: String = "https://accounts.google.com"
    public var subject: String
    public var email: String
    public var label: String
    public var scopes: Set<String>
    public var status: AccountStatus = .discovering
    public var generation: Int = 0
    public var lastSync: Date?
    public var retryAfter: Date?
    public var consecutiveFailures: Int?
    public var isDemo: Bool = false
    public init(id: AccountID = .init(), subject: String, email: String, label: String? = nil, scopes: Set<String>, isDemo: Bool = false) {
        self.id = id; self.subject = subject; self.email = email; self.label = label ?? email; self.scopes = scopes; self.isDemo = isDemo
    }
}

public enum GoogleScope {
    public static let events = "https://www.googleapis.com/auth/calendar.events"
    public static let calendarList = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    public static let settings = "https://www.googleapis.com/auth/calendar.settings.readonly"
    public static let freebusy = "https://www.googleapis.com/auth/calendar.events.freebusy"
    public static let all: Set<String> = ["openid", "email", events, calendarList, settings, freebusy]
}

public struct CalendarSource: Identifiable, Codable, Equatable, Sendable {
    public var key: CalendarKey
    public var id: String { key.id }
    public var title: String
    public var timeZone: String
    public var role: String
    public var color: String
    public var primary: Bool
    public var hidden: Bool
    public var syncEnabled: Bool
    public var visible: Bool
    public var deleted: Bool = false
    public var generation: Int = 0
    public var writeEpoch: Int = 0
    public var defaultReminderMinutes: [Int] = [10]
    public var allowsMeet: Bool = false
    public var lastSync: Date?
    public var lastError: String?
    public init(key: CalendarKey, title: String, timeZone: String = "UTC", role: String = "reader", color: String = "#5379C4", primary: Bool = false, hidden: Bool = false, syncEnabled: Bool = true, visible: Bool = true) {
        self.key = key; self.title = title; self.timeZone = timeZone; self.role = role; self.color = color; self.primary = primary; self.hidden = hidden; self.syncEnabled = syncEnabled; self.visible = visible
    }
    public var writable: Bool { !deleted && ["owner", "writer", "writerWithoutPrivateAccess"].contains(role) }
    public var freeBusyOnly: Bool { role == "freeBusyReader" }
    public var readable: Bool { !deleted && ["owner", "writer", "writerWithoutPrivateAccess", "reader"].contains(role) }
}
