import Foundation
@preconcurrency import UserNotifications
import CalendarCore

@MainActor public final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private let repository: CalendarRepository
    private var reconciling = false
    private var pendingPlan: (desired: [PlannedReminder], valid: [PlannedReminder])?
    private var removedAccounts: Set<AccountID> = []
    public var openEvent: ((EventKey, Bool) -> Void)?
    public var snoozeMinutes = 5
    public init(repository: CalendarRepository) {
        self.repository = repository; super.init(); center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(identifier: "DAYFOLD_EVENT", actions: [UNNotificationAction(identifier: "OPEN", title: "Open", options: [.foreground]), UNNotificationAction(identifier: "JOIN", title: "Join", options: [.foreground]), UNNotificationAction(identifier: "SNOOZE", title: "Snooze", options: [])], intentIdentifiers: [])])
    }
    public func permission() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    public func requestPermission() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
    public func reconcile(_ reminders: [PlannedReminder], validReminders: [PlannedReminder]) async throws {
        pendingPlan = (reminders, validReminders)
        guard !reconciling else { return }
        reconciling = true; defer { reconciling = false }
        while let plan = pendingPlan {
            pendingPlan = nil
            try await apply(plan.desired, validReminders: plan.valid)
        }
    }
    private func apply(_ reminders: [PlannedReminder], validReminders: [PlannedReminder]) async throws {
        let requests = await center.pendingNotificationRequests(), desired = Set(reminders.map(\.id))
        let valid = Dictionary(uniqueKeysWithValues: validReminders.map { ($0.id, $0) })
        func validOrigin(_ request: UNNotificationRequest) -> PlannedReminder? {
            let origin = request.content.userInfo["origin"] as? String ?? request.identifier
            return valid[origin]
        }
        let remove = requests.filter { request in
            guard request.identifier.hasPrefix("dayfold.") else { return false }
            return request.identifier.hasPrefix("dayfold.snooze.") ? validOrigin(request) == nil : !desired.contains(request.identifier)
        }.map(\.identifier)
        center.removePendingNotificationRequests(withIdentifiers: remove)
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request).filter { $0.identifier.hasPrefix("dayfold.") && validOrigin($0) == nil }.map(\.identifier))
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
            guard !removedAccounts.contains(reminder.event.calendar.account) else { continue }
            let data = try JSONEncoder().encode(reminder); ledger[reminder.id] = data
            let content = UNMutableNotificationContent(); content.title = reminder.title; content.body = reminder.source; content.sound = .default; content.categoryIdentifier = "DAYFOLD_EVENT"
            content.userInfo = ["event": try JSONEncoder().encode(reminder.event).base64EncodedString(), "origin": reminder.id]
            let delay = reminder.fire.timeIntervalSinceNow; guard delay > 0 else { continue }
            if let existing = requests.first(where: { $0.identifier == reminder.id }), existing.content.title == content.title, existing.content.body == content.body { continue }
            try await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false)))
            if removedAccounts.contains(reminder.event.calendar.account) { center.removePendingNotificationRequests(withIdentifiers: [reminder.id]) }
        }
        try await repository.setLedger(ledger)
    }
    public func removeAllForAccount(_ account: AccountID) async {
        removedAccounts.insert(account)
        let requests = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        func belongs(_ request: UNNotificationRequest) -> Bool {
            guard let s = request.content.userInfo["event"] as? String, let d = Data(base64Encoded: s), let key = try? JSONDecoder().decode(EventKey.self, from: d) else { return false }; return key.calendar.account == account
        }
        center.removePendingNotificationRequests(withIdentifiers: requests.filter(belongs).map(\.identifier))
        center.removeDeliveredNotifications(withIdentifiers: delivered.map(\.request).filter(belongs).map(\.identifier))
    }
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let request = response.notification.request
        let encoded = request.content.userInfo["event"] as? String
        let action = response.actionIdentifier
        await handle(request: request, encoded: encoded, action: action)
    }
    private func handle(request: UNNotificationRequest, encoded: String?, action: String) async {
            guard let encoded, let data = Data(base64Encoded: encoded), let key = try? JSONDecoder().decode(EventKey.self, from: data), let event = try? await repository.event(key), !event.cancelled, event.response != "declined", !event.redacted else { if let encoded, let data = Data(base64Encoded: encoded), let key = try? JSONDecoder().decode(EventKey.self, from: data) { openEvent?(key, false) }; return }
            if action == "SNOOZE" {
                guard let preferences = try? await repository.preferences(), preferences.notifications else { return }
                let content = UNMutableNotificationContent(); content.title = preferences.privateNotifications ? "Busy event" : event.title; content.body = preferences.privateNotifications ? "Dayfold reminder" : request.content.body; content.categoryIdentifier = "DAYFOLD_EVENT"; content.userInfo = ["event": encoded, "origin": request.content.userInfo["origin"] as? String ?? request.identifier]; content.sound = .default
                try? await center.add(UNNotificationRequest(identifier: "dayfold.snooze." + UUID().uuidString, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: Double(snoozeMinutes * 60), repeats: false)))
            } else { openEvent?(key, action == "JOIN") }
    }
}
