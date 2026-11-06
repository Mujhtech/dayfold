import Foundation

public enum MutationState: String, Codable, CaseIterable, Sendable {
    case queued, executing, retryScheduled, uncertain, blockedAuthorization, conflicted, failed, confirmed, cancelled
    public var label: String {
        switch self {
        case .queued: "Saved on this Mac, waiting to sync"; case .executing: "Sending to Google"
        case .retryScheduled: "Waiting to retry"; case .uncertain: "Checking with Google"
        case .blockedAuthorization: "Sign in again to sync"; case .conflicted: "Review changes"
        case .failed: "Needs correction"; case .confirmed: "Confirmed"; case .cancelled: "Cancelled"
        }
    }
    public var pending: Bool { self != .confirmed && self != .cancelled }
}
public enum MutationKind: String, Codable, Sendable { case create, patch, delete, rsvp }
public struct Mutation: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var key: EventKey
    public var kind: MutationKind
    public var fields: JSONObject
    public var base: CalendarEvent?
    public var state: MutationState = .queued
    public var attempts = 0
    public var retryAfter: Date?
    public var errorCategory: String?
    public var predecessor: String?
    public var confirmedEvent: CalendarEvent?
    public var reverses: String?
    public var reversedBy: String?
    public var reversalDepth: Int?
    public var sendUpdates: String
    public var created: Date
    public init(id: String = UUID().uuidString.lowercased(), key: EventKey, kind: MutationKind, fields: JSONObject, base: CalendarEvent?, sendUpdates: String = "all", created: Date = Date()) {
        self.id = id; self.key = key; self.kind = kind; self.fields = fields; self.base = base; self.sendUpdates = sendUpdates; self.created = created
    }
}
public struct EventDraft: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var calendar: CalendarKey?
    public var source: CalendarEvent?
    public var fields: JSONObject
    public var updated: Date
    public var requiresOnlineReview: Bool
    public var repairingMutationID: String?
    public init(id: String = UUID().uuidString.lowercased(), calendar: CalendarKey?, source: CalendarEvent? = nil, fields: JSONObject = [:], updated: Date = Date(), requiresOnlineReview: Bool = false) {
        self.id = id; self.calendar = calendar; self.source = source; self.fields = fields; self.updated = updated; self.requiresOnlineReview = requiresOnlineReview
    }
}
public struct EventConflict: Codable, Equatable, Sendable, Identifiable {
    public var id: String { mutation.id }
    public var mutation: Mutation
    public var remote: CalendarEvent?
    public var fields: [String]
    public init(mutation: Mutation, remote: CalendarEvent?, fields: [String]) { self.mutation = mutation; self.remote = remote; self.fields = fields }
}
public struct CacheCoverage: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var calendar: CalendarKey
    public var interval: DateInterval
    public var fetched: Date
    public var generation: Int
    public var writeEpoch: Int
    public var stale: Bool
}
public struct RepositorySnapshot: Sendable {
    public var accounts: [CalendarAccount]
    public var calendars: [CalendarSource]
    public var events: [CalendarEvent]
    public var mutations: [Mutation]
    public var drafts: [EventDraft]
    public var conflicts: [EventConflict]
    public var coverage: [CacheCoverage]
    public var recentChanges: [Mutation]
}
public struct Preferences: Codable, Equatable, Sendable {
    public var defaultCalendar: CalendarKey?
    public var defaultDuration = 30
    public var weekStart = 0
    public var showWeekends = true
    public var workStart = 8
    public var workEnd = 18
    public var hourHeight: Double = 64
    public var displayZone = "device"
    public var secondaryZone = ""
    public var appearance = "system"
    public var menuStyle = "time"
    public var includeTentative = true
    public var showDeclined = false
    public var notifications = false
    public var privateNotifications = false
    public var allDayHour = 9
    public var snoozeMinutes = 5
    public var parserLocale = "en_GB"
    public var savedSets: [String: Set<String>] = [:]
    public var startupView = "restore"
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case defaultCalendar, defaultDuration, weekStart, showWeekends, workStart, workEnd, hourHeight, displayZone, secondaryZone, appearance, menuStyle, includeTentative, showDeclined, notifications, privateNotifications, allDayHour, snoozeMinutes, parserLocale, savedSets, startupView
    }
    public init(from decoder: any Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultCalendar = try c.decodeIfPresent(CalendarKey.self, forKey: .defaultCalendar)
        defaultDuration = try c.decodeIfPresent(Int.self, forKey: .defaultDuration) ?? defaultDuration
        weekStart = try c.decodeIfPresent(Int.self, forKey: .weekStart) ?? weekStart
        showWeekends = try c.decodeIfPresent(Bool.self, forKey: .showWeekends) ?? showWeekends
        workStart = try c.decodeIfPresent(Int.self, forKey: .workStart) ?? workStart
        workEnd = try c.decodeIfPresent(Int.self, forKey: .workEnd) ?? workEnd
        hourHeight = try c.decodeIfPresent(Double.self, forKey: .hourHeight) ?? hourHeight
        displayZone = try c.decodeIfPresent(String.self, forKey: .displayZone) ?? displayZone
        secondaryZone = try c.decodeIfPresent(String.self, forKey: .secondaryZone) ?? secondaryZone
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? appearance
        menuStyle = try c.decodeIfPresent(String.self, forKey: .menuStyle) ?? menuStyle
        includeTentative = try c.decodeIfPresent(Bool.self, forKey: .includeTentative) ?? includeTentative
        showDeclined = try c.decodeIfPresent(Bool.self, forKey: .showDeclined) ?? showDeclined
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? notifications
        privateNotifications = try c.decodeIfPresent(Bool.self, forKey: .privateNotifications) ?? privateNotifications
        allDayHour = try c.decodeIfPresent(Int.self, forKey: .allDayHour) ?? allDayHour
        snoozeMinutes = try c.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? snoozeMinutes
        parserLocale = try c.decodeIfPresent(String.self, forKey: .parserLocale) ?? parserLocale
        savedSets = try c.decodeIfPresent([String: Set<String>].self, forKey: .savedSets) ?? savedSets
        startupView = try c.decodeIfPresent(String.self, forKey: .startupView) ?? startupView
    }
    public var timeZone: TimeZone { displayZone == "device" ? .current : TimeZone(identifier: displayZone) ?? .current }
}
