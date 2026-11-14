import Foundation
@preconcurrency import UserNotifications
import CalendarCore

@MainActor public final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    private let center: any NotificationDeliveryCenter
    private let repository: CalendarRepository
    private var reconciling = false
    private var pendingPlan: (desired: [PlannedReminder], valid: [PlannedReminder])?
    private var reconciliationWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var removedAccounts: Set<AccountID> = []
    private var remoteOwnedIDs: Set<String> = []
    private var relayDeliveriesInFlight: Set<String> = []
    public var openEvent: ((EventKey, Bool) -> Void)?
    /// The owner validates the local reminder revision and durably deduplicates
    /// the opaque notification ID. A missing or rejecting hook suppresses alerts.
    public var remoteWillPresent: (@MainActor @Sendable (RemotePushPayload) async -> Bool)?
    public var remoteDidReceive: (@MainActor @Sendable (RemotePushPayload, String) async -> Void)?
    public var snoozeMinutes = 5

    public convenience init(repository: CalendarRepository) {
        self.init(repository: repository, center: SystemNotificationDeliveryCenter())
    }

    init(repository: CalendarRepository, center: any NotificationDeliveryCenter) {
        self.repository = repository
        self.center = center
        super.init()
        center.configure(delegate: self)
    }

    public func permission() async -> UNAuthorizationStatus { await center.authorizationStatus() }
    public func requestPermission() async throws -> Bool { try await center.requestAuthorization() }

    /// Pass persisted remote ownership before allowing the server to deliver.
    /// Completion waits for coalesced work and in-flight local adds to finish,
    /// so ownership handoff cannot race an older local schedule. Snoozes stay local.
    public func reconcile(_ reminders: [PlannedReminder], validReminders: [PlannedReminder], remoteOwnedIDs: Set<String> = []) async throws {
        try Task.checkCancellation()
        self.remoteOwnedIDs = remoteOwnedIDs
        pendingPlan = (reminders, validReminders)
        if reconciling {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { reconciliationWaiters[id] = continuation }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.reconciliationWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
                }
            }
        } else {
            reconciling = true
            do {
                while let plan = pendingPlan {
                    try Task.checkCancellation()
                    pendingPlan = nil
                    try await apply(plan.desired, validReminders: plan.valid)
                }
                finishReconciliation(.success(()))
            } catch {
                finishReconciliation(.failure(error))
                throw error
            }
        }
        try Task.checkCancellation()
        // A newer plan may supersede this call while it waits. Never authorize
        // an ownership handoff if that newer plan restored one of its originals.
        guard remoteOwnedIDs.isSubset(of: self.remoteOwnedIDs) else { throw CalendarError.staleGeneration }
    }

    private func finishReconciliation(_ result: Result<Void, any Error>) {
        reconciling = false
        let waiters = Array(reconciliationWaiters.values)
        reconciliationWaiters.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }
    private func apply(_ reminders: [PlannedReminder], validReminders: [PlannedReminder]) async throws {
        let requests = await center.pendingRequests()
        let desired = Set(reminders.map(\.id)).subtracting(remoteOwnedIDs)
        let valid = Dictionary(validReminders.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        func validOrigin(_ request: UNNotificationRequest) -> PlannedReminder? {
            let origin = request.content.userInfo["origin"] as? String ?? request.identifier
            return valid[origin]
        }
        let remove = requests.filter { request in
            guard request.identifier.hasPrefix("dayfold.") else { return false }
            return Self.isImmediateOrSnoozed(request.identifier) ? validOrigin(request) == nil : !desired.contains(request.identifier)
        }.map(\.identifier)
        center.removePending(identifiers: remove)
        let delivered = await center.deliveredRequests()
        center.removeDelivered(identifiers: delivered.filter { $0.identifier.hasPrefix("dayfold.") && validOrigin($0) == nil }.map(\.identifier))
        let status = await permission(); guard status == .authorized || status == .provisional else { return }
        // Snoozes retain their local delivery time but follow cancellation, rescheduling,
        // permission and notification-privacy changes of their original occurrence.
        for request in requests where request.identifier.hasPrefix("dayfold.snooze.") {
            guard let reminder = validOrigin(request) else { continue }
            if request.content.title != reminder.title || request.content.body != reminder.source,
               let content = request.content.mutableCopy() as? UNMutableNotificationContent {
                content.title = reminder.title; content.body = reminder.source
                try await center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: request.trigger))
            }
        }
        var ledger: [String: Data] = [:]
        for reminder in reminders {
            guard !removedAccounts.contains(reminder.event.calendar.account), !remoteOwnedIDs.contains(reminder.id) else { continue }
            let data = try JSONEncoder().encode(reminder); ledger[reminder.id] = data
            let content = UNMutableNotificationContent(); content.title = reminder.title; content.body = reminder.source; content.sound = .default; content.categoryIdentifier = "DAYFOLD_EVENT"
            content.userInfo = ["event": try JSONEncoder().encode(reminder.event).base64EncodedString(), "origin": reminder.id]
            let delay = reminder.fire.timeIntervalSinceNow; guard delay > 0 else { continue }
            if let existing = requests.first(where: { $0.identifier == reminder.id }), existing.content.title == content.title, existing.content.body == content.body { continue }
            try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)))
            if removedAccounts.contains(reminder.event.calendar.account) || remoteOwnedIDs.contains(reminder.id) {
                center.removePending(identifiers: [reminder.id])
            }
        }
        try await repository.setLedger(ledger)
    }

    /// Returns true when this notification is already pending/delivered or was
    /// accepted by the local notification service. The coordinator owns durable
    /// deduplication and must first claim delivery from the relay.
    public func deliverRelayReminder(reminder: PlannedReminder, notificationID: UUID) async -> Bool {
        let identifier = Self.relayIdentifier(notificationID)
        guard relayDeliveriesInFlight.insert(identifier).inserted else { return false }
        defer { relayDeliveriesInFlight.remove(identifier) }
        let status = await permission()
        guard status == .authorized || status == .provisional,
              let current = await currentReminder(origin: reminder.id, eventKey: reminder.event),
              let content = try? Self.content(for: current) else { return false }
        let pending = await center.pendingRequests()
        if pending.contains(where: { $0.identifier == identifier }) { return true }
        let delivered = await center.deliveredRequests()
        if delivered.contains(where: { $0.identifier == identifier }) { return true }
        content.userInfo["relay_notification_id"] = notificationID.uuidString.lowercased()
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            if removedAccounts.contains(reminder.event.calendar.account) {
                center.removePending(identifiers: [identifier])
                center.removeDelivered(identifiers: [identifier])
                return false
            }
            return true
        } catch {
            return false
        }
    }

    public func removeAllForAccount(_ account: AccountID) async {
        removedAccounts.insert(account)
        let requests = await center.pendingRequests()
        let delivered = await center.deliveredRequests()
        func belongs(_ request: UNNotificationRequest) -> Bool {
            guard let s = request.content.userInfo["event"] as? String, let d = Data(base64Encoded: s), let key = try? JSONDecoder().decode(EventKey.self, from: d) else { return false }; return key.calendar.account == account
        }
        center.removePending(identifiers: requests.filter(belongs).map(\.identifier))
        center.removeDelivered(identifiers: delivered.filter(belongs).map(\.identifier))
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await presentationOptions(for: notification.request)
    }

    func presentationOptions(for request: UNNotificationRequest) async -> UNNotificationPresentationOptions {
        if Self.isRemote(request) {
            guard let payload = RemotePushPayload(userInfo: request.content.userInfo),
                  let remoteWillPresent else { return [] }
            let accepted = await remoteWillPresent(payload)
            return accepted && payload.kind == .reminderDue ? [.banner, .sound] : []
        }
        guard request.identifier.hasPrefix("dayfold."),
              let key = Self.eventKey(request.content.userInfo["event"] as? String),
              let current = await currentReminder(origin: request.content.userInfo["origin"] as? String ?? request.identifier, eventKey: key),
              request.content.title == current.title, request.content.body == current.source else { return [] }
        // An ownership transition can race a previously submitted local request.
        if remoteOwnedIDs.contains(current.id) && !Self.isImmediateOrSnoozed(request.identifier) { return [] }
        return [.banner, .sound]
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        let action = response.actionIdentifier
        await handleResponse(request: request, action: action)
    }

    func handleResponse(request: UNNotificationRequest, action: String) async {
        if Self.isRemote(request) {
            guard let payload = RemotePushPayload(userInfo: request.content.userInfo) else { return }
            await remoteDidReceive?(payload, action)
            return
        }
        guard action != UNNotificationDismissActionIdentifier else { return }
        let encoded = request.content.userInfo["event"] as? String
            guard let encoded, let data = Data(base64Encoded: encoded), let key = try? JSONDecoder().decode(EventKey.self, from: data), let event = try? await repository.event(key), !event.cancelled, event.response != "declined", !event.redacted else { if let encoded, let data = Data(base64Encoded: encoded), let key = try? JSONDecoder().decode(EventKey.self, from: data) { openEvent?(key, false) }; return }
            if action == "SNOOZE" {
                let origin = request.content.userInfo["origin"] as? String ?? request.identifier
                guard await currentReminder(origin: origin, eventKey: key) != nil,
                      let preferences = try? await repository.preferences(), preferences.notifications else { return }
                let content = UNMutableNotificationContent(); content.title = preferences.privateNotifications ? "Busy event" : event.title; content.body = preferences.privateNotifications ? "Dayfold reminder" : request.content.body; content.categoryIdentifier = "DAYFOLD_EVENT"; content.userInfo = ["event": encoded, "origin": request.content.userInfo["origin"] as? String ?? request.identifier]; content.sound = .default
                try? await center.add(UNNotificationRequest(identifier: "dayfold.snooze." + UUID().uuidString, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: Double(snoozeMinutes * 60), repeats: false)))
            } else { openEvent?(key, action == "JOIN") }
    }

    private func currentReminder(origin: String, eventKey: EventKey) async -> PlannedReminder? {
        guard !removedAccounts.contains(eventKey.calendar.account),
              let preferences = try? await repository.preferences(), preferences.notifications,
              let event = try? await repository.event(eventKey),
              let source = try? await repository.calendar(eventKey.calendar) else { return nil }
        return ReminderPlanner.plan(events: [event], calendars: [source], preferences: preferences, now: Date(), includeRecentPast: true)
            .first { $0.id == origin }
    }

    private static func content(for reminder: PlannedReminder) throws -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.source
        content.sound = .default
        content.categoryIdentifier = "DAYFOLD_EVENT"
        content.userInfo = ["event": try JSONEncoder().encode(reminder.event).base64EncodedString(), "origin": reminder.id]
        return content
    }

    private static func eventKey(_ encoded: String?) -> EventKey? {
        guard let encoded, let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(EventKey.self, from: data)
    }

    private static func isImmediateOrSnoozed(_ identifier: String) -> Bool {
        identifier.hasPrefix("dayfold.snooze.") || identifier.hasPrefix("dayfold.relay.")
    }

    private static func isRemote(_ request: UNNotificationRequest) -> Bool {
        request.trigger is UNPushNotificationTrigger || request.content.userInfo["notification_id"] != nil
    }

    static func relayIdentifier(_ notificationID: UUID) -> String { "dayfold.relay." + notificationID.uuidString.lowercased() }
}
