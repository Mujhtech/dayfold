import Foundation

/// Only routing metadata is persisted here. The installation bearer stays in Keychain.
public struct RelayConfiguration: Codable, Equatable, Sendable {
    public var origin: URL
    public var deviceID: UUID
    public var enabled: Bool
    public var reminders: Bool
    public init(origin: URL, deviceID: UUID, enabled: Bool = true, reminders: Bool = true) {
        self.origin = origin; self.deviceID = deviceID; self.enabled = enabled; self.reminders = reminders
    }
}

public struct RelayScope: Codable, Hashable, Sendable {
    public var account: AccountID
    public var calendar: CalendarKey?
    public init(account: AccountID, calendar: CalendarKey? = nil) { self.account = account; self.calendar = calendar }
}

public struct RelayWatchState: Codable, Equatable, Sendable {
    public var scopeID: UUID
    public var scope: RelayScope
    public var channelID: UUID
    public var resourceID: String?
    public var expiresAt: Date
    public var activated = false
    public var retired = false
    public init(scopeID: UUID, scope: RelayScope, channelID: UUID, resourceID: String? = nil,
                expiresAt: Date, activated: Bool = false, retired: Bool = false) {
        self.scopeID = scopeID; self.scope = scope; self.channelID = channelID
        self.resourceID = resourceID; self.expiresAt = expiresAt; self.activated = activated; self.retired = retired
    }
}

public struct RelayReminderState: Codable, Equatable, Sendable {
    public var remoteID: UUID
    public var reminder: PlannedReminder
    public var revision: Int64 = 1
    public var uploadedRevision: Int64?
    public var deleted = false
    public var deletionConfirmed = false
    /// Set durably before uploading, including ambiguous network outcomes.
    public var owned = true
    public var expiresAt: Date { reminder.fire.addingTimeInterval(15 * 60) }
    public init(remoteID: UUID = UUID(), reminder: PlannedReminder, revision: Int64 = 1,
                uploadedRevision: Int64? = nil, deleted: Bool = false,
                deletionConfirmed: Bool = false, owned: Bool = true) {
        self.remoteID = remoteID; self.reminder = reminder; self.revision = revision
        self.uploadedRevision = uploadedRevision; self.deleted = deleted
        self.deletionConfirmed = deletionConfirmed; self.owned = owned
    }
}

public struct RelayState: Codable, Equatable, Sendable {
    public var configuration: RelayConfiguration?
    public var cursor: Int64 = 0
    public var acknowledgedCursor: Int64 = 0
    public var watches: [RelayWatchState] = []
    public var reminders: [String: RelayReminderState] = [:]
    public var delivered: [UUID: Date] = [:]
    public var pendingSync: Set<RelayScope> = []
    public var fullSyncPending = false
    public var pendingResyncCursor: Int64?
    public var removingAccounts: Set<AccountID> = []
    public init(configuration: RelayConfiguration? = nil) { self.configuration = configuration }
    public var remoteOwnedIDs: Set<String> {
        Set(reminders.filter { $0.value.owned && !$0.value.deletionConfirmed }.map(\.key))
    }
    enum CodingKeys: String, CodingKey {
        case configuration, cursor, acknowledgedCursor, watches, reminders, delivered
        case pendingSync, fullSyncPending, pendingResyncCursor, removingAccounts
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        configuration = try values.decodeIfPresent(RelayConfiguration.self, forKey: .configuration)
        cursor = try values.decodeIfPresent(Int64.self, forKey: .cursor) ?? 0
        acknowledgedCursor = try values.decodeIfPresent(Int64.self, forKey: .acknowledgedCursor) ?? 0
        watches = try values.decodeIfPresent([RelayWatchState].self, forKey: .watches) ?? []
        reminders = try values.decodeIfPresent([String: RelayReminderState].self, forKey: .reminders) ?? [:]
        delivered = try values.decodeIfPresent([UUID: Date].self, forKey: .delivered) ?? [:]
        pendingSync = try values.decodeIfPresent(Set<RelayScope>.self, forKey: .pendingSync) ?? []
        fullSyncPending = try values.decodeIfPresent(Bool.self, forKey: .fullSyncPending) ?? false
        pendingResyncCursor = try values.decodeIfPresent(Int64.self, forKey: .pendingResyncCursor)
        removingAccounts = try values.decodeIfPresent(Set<AccountID>.self, forKey: .removingAccounts) ?? []
    }
}

public struct RelayReconciliation: Equatable, Sendable {
    public var accounts: [CalendarAccount]
    public var calendars: [CalendarSource]
    public var desired: [PlannedReminder]
    public var valid: [PlannedReminder]
    public var remindersEnabled: Bool
    public var notificationAuthorization: Bool
    public init(accounts: [CalendarAccount], calendars: [CalendarSource], desired: [PlannedReminder], valid: [PlannedReminder], remindersEnabled: Bool, notificationAuthorization: Bool) {
        self.accounts = accounts; self.calendars = calendars; self.desired = desired; self.valid = valid
        self.remindersEnabled = remindersEnabled; self.notificationAuthorization = notificationAuthorization
    }
}

public struct RelayConnectionStatus: Equatable, Sendable {
    public var connected: Bool
    public var message: String
    public var apnsEnabled: Bool
    public var deviceRevoked: Bool
    public init(connected: Bool = false, message: String, apnsEnabled: Bool = false, deviceRevoked: Bool = false) {
        self.connected = connected; self.message = message; self.apnsEnabled = apnsEnabled; self.deviceRevoked = deviceRevoked
    }
}

public enum RelayProcessingError: Error, LocalizedError, Sendable {
    case syncIncomplete, deliveryUnavailable, configurationChanged
    public var errorDescription: String? {
        switch self {
        case .syncIncomplete: "Calendar updates are waiting for a successful refresh."
        case .deliveryUnavailable: "Reminder delivery is waiting for this Mac."
        case .configurationChanged: "The real-time connection changed. Try again."
        }
    }
}
