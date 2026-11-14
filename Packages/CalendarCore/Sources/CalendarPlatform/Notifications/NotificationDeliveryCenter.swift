import Foundation
@preconcurrency import UserNotifications

/// Internal test seam. Tests can exercise scheduling without touching macOS's
/// notification service, requesting permission, or displaying an alert.
@MainActor protocol NotificationDeliveryCenter {
    func configure(delegate: any UNUserNotificationCenterDelegate)
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func pendingRequests() async -> [UNNotificationRequest]
    func deliveredRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePending(identifiers: [String])
    func removeDelivered(identifiers: [String])
}

@MainActor struct SystemNotificationDeliveryCenter: NotificationDeliveryCenter {
    private let center = UNUserNotificationCenter.current()

    func configure(delegate: any UNUserNotificationCenterDelegate) {
        center.delegate = delegate
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "DAYFOLD_EVENT", actions: [
                UNNotificationAction(identifier: "OPEN", title: "Open", options: [.foreground]),
                UNNotificationAction(identifier: "JOIN", title: "Join", options: [.foreground]),
                UNNotificationAction(identifier: "SNOOZE", title: "Snooze", options: [])
            ], intentIdentifiers: [])
        ])
    }

    func authorizationStatus() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    func requestAuthorization() async throws -> Bool { try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
    func pendingRequests() async -> [UNNotificationRequest] { await center.pendingNotificationRequests() }
    func deliveredRequests() async -> [UNNotificationRequest] { await center.deliveredNotifications().map(\.request) }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func removePending(identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removeDelivered(identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
}
