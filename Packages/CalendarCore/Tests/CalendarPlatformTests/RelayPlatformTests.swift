import Foundation
import Security
import Testing
@preconcurrency import UserNotifications
import CalendarCore
@testable import CalendarPlatform

private final class MemoryRelayStorage: RelayCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]
    private var inaccessible = false
    private var removals = 0

    var keys: [String] { lock.withLock { Array(records.keys) } }
    var removalCount: Int { lock.withLock { removals } }
    func setLocked(_ locked: Bool) { lock.withLock { inaccessible = locked } }
    func replaceAll(with data: Data) { lock.withLock { for key in records.keys { records[key] = data } } }
    func read(account: String) throws -> Data? {
        try lock.withLock {
            if inaccessible { throw RelayCredentialError.keychainUnavailable }
            return records[account]
        }
    }
    func save(_ data: Data, account: String) throws {
        try lock.withLock {
            if inaccessible { throw RelayCredentialError.keychainUnavailable }
            records[account] = data
        }
    }
    func remove(account: String) throws {
        try lock.withLock {
            if inaccessible { throw RelayCredentialError.keychainUnavailable }
            removals += 1
            records[account] = nil
        }
    }
}

@Test func relayCredentialsStayIsolatedByStoreAndRedactedInDiagnostics() async throws {
    let storage = MemoryRelayStorage()
    let real = RelayCredentialStore(namespace: "/stores/real/calendar.sqlite", storage: storage)
    let demo = RelayCredentialStore(namespace: "/stores/demo/calendar.sqlite", storage: storage)
    let credentials = RelayCredentials(origin: URL(string: "https://relay.example.test")!, deviceID: UUID(), token: String(repeating: "a", count: 64))
    #expect(try await real.load() == nil)
    try await real.save(credentials)
    let restored = try #require(try await real.load())
    #expect(restored.origin.absoluteString == "https://relay.example.test/")
    #expect(restored.deviceID == credentials.deviceID)
    #expect(restored.token == credentials.token)
    #expect(try await demo.load() == nil)
    try await demo.save(RelayCredentials(origin: credentials.origin, deviceID: UUID(), token: String(repeating: "b", count: 64)))
    #expect(storage.keys.count == 2)
    #expect(storage.keys.allSatisfy { !$0.contains("calendar.sqlite") })
    #expect(!String(describing: credentials).contains(credentials.token))
    #expect(!String(reflecting: credentials).contains(credentials.token))
    try await real.delete()
    #expect(try await real.load() == nil)
    #expect(try await demo.load() != nil)
}

@Test func relayCredentialValidationCannotOverwriteOrDeleteARecoverableSecret() async throws {
    let storage = MemoryRelayStorage()
    let store = RelayCredentialStore(namespace: "real", storage: storage)
    let credentials = RelayCredentials(origin: URL(string: "https://relay.example.test")!, deviceID: UUID(), token: String(repeating: "c", count: 64))
    try await store.save(credentials)
    for origin in ["http://relay.example.test", "https://secret@relay.example.test", "https://relay.example.test/path", "https://relay.example.test?token=secret"] {
        await #expect(throws: RelayCredentialError.invalidCredentials) {
            try await store.save(RelayCredentials(origin: URL(string: origin)!, deviceID: UUID(), token: credentials.token))
        }
    }
    await #expect(throws: RelayCredentialError.invalidCredentials) {
        try await store.save(RelayCredentials(origin: credentials.origin, deviceID: UUID(), token: "short"))
    }
    #expect(try await store.load()?.deviceID == credentials.deviceID)
    storage.setLocked(true)
    await #expect(throws: RelayCredentialError.keychainUnavailable) { try await store.load() }
    await #expect(throws: RelayCredentialError.keychainUnavailable) { try await store.save(credentials) }
    #expect(storage.removalCount == 0)
    storage.setLocked(false)
    #expect(try await store.load()?.token == credentials.token)
    storage.replaceAll(with: Data("{\"version\":999}".utf8))
    await #expect(throws: RelayCredentialError.corruptRecord) { try await store.load() }
    #expect(storage.removalCount == 0)
}

@Test func relayKeychainUsesPrivateMacStorageAndExplicitLoopbackOptIn() async throws {
    let query = try SystemRelayCredentialStorage().query(account: "fixture", mode: .legacyFileBased)
    #expect(query[kSecAttrService as String] as? String == "mujhtech.dayfold.relay")
    #expect(query[kSecUseDataProtectionKeychain as String] == nil)
    #expect(query[kSecAttrSynchronizable as String] == nil)
    #expect(query[kSecAttrAccessGroup as String] == nil)
    let storage = MemoryRelayStorage()
    let production = RelayCredentialStore(namespace: "loopback", storage: storage)
    let development = RelayCredentialStore(namespace: "loopback", allowLoopbackHTTP: true, storage: storage)
    let credentials = RelayCredentials(origin: URL(string: "http://127.0.0.1:8080")!, deviceID: UUID(), token: String(repeating: "d", count: 64))
    await #expect(throws: RelayCredentialError.invalidCredentials) { try await production.save(credentials) }
    try await development.save(credentials)
    #expect(try await development.load()?.origin.absoluteString == "http://127.0.0.1:8080/")
    await #expect(throws: RelayCredentialError.corruptRecord) { try await production.load() }
    await #expect(throws: RelayCredentialError.invalidNamespace) {
        try await RelayCredentialStore(namespace: "", storage: storage).load()
    }
}

private func remoteInfo(kind: String = "reminder_due", revision: Any = NSNumber(value: 4)) -> [AnyHashable: Any] {
    ["notification_id": "00000000-0000-0000-0000-000000000001", "subject_id": "00000000-0000-0000-0000-000000000002", "kind": kind, "revision": revision]
}

@Test func remotePushParsingRequiresOpaqueIDsAndAnExactPositiveReminderRevision() throws {
    let reminder = try #require(RemotePushPayload(userInfo: remoteInfo()))
    #expect(reminder.notificationID == UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    #expect(reminder.subjectID == UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
    #expect(reminder.kind == .reminderDue && reminder.revision == 4)
    for revision: Any in [NSNull(), NSNumber(value: true), NSNumber(value: 0), NSNumber(value: -1), NSNumber(value: 1.5), NSNumber(value: UInt64.max), "4"] {
        #expect(RemotePushPayload(userInfo: remoteInfo(revision: revision)) == nil)
    }
    #expect(RemotePushPayload(userInfo: remoteInfo(kind: "unknown")) == nil)
    #expect(RemotePushPayload(userInfo: remoteInfo(kind: "calendar_changed")) == nil)
    #expect(RemotePushPayload(userInfo: remoteInfo(kind: "calendar_changed", revision: NSNull()))?.kind == .calendarChanged)
    var malformed = remoteInfo()
    malformed["notification_id"] = "not a UUID"
    #expect(RemotePushPayload(userInfo: malformed) == nil)
}

@Test func pushRegistrationRequiresProvisionedMacEntitlementAndPreservesTokenBytes() {
    #expect(RemotePushRegistration.availability(entitlement: "development", isAdHoc: false) == .available(environment: .sandbox))
    #expect(RemotePushRegistration.availability(entitlement: "production", isAdHoc: false) == .available(environment: .production))
    #expect(RemotePushRegistration.availability(entitlement: "development", isAdHoc: true).environment == nil)
    #expect(RemotePushRegistration.availability(entitlement: nil, isAdHoc: false).environment == nil)
    #expect(RemotePushRegistration.availability(entitlement: "sandbox", isAdHoc: false).environment == nil)
    #expect(RemotePushRegistration.tokenString(from: Data([0, 1, 15, 16, 127, 255])) == "00010f107fff")
    #expect(RemotePushRegistration.tokenString(from: Data(repeating: 0xab, count: 41)) == String(repeating: "ab", count: 41))
}

@MainActor private final class FakeNotificationCenter: NotificationDeliveryCenter {
    var status: UNAuthorizationStatus = .authorized
    var pending: [UNNotificationRequest] = []
    var delivered: [UNNotificationRequest] = []
    var additions: [UNNotificationRequest] = []
    var failAdd = false
    var beforeAdd: (@MainActor (UNNotificationRequest) async -> Void)?
    var configured = false
    func configure(delegate: any UNUserNotificationCenterDelegate) { configured = true }
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async throws -> Bool { status == .authorized }
    func pendingRequests() async -> [UNNotificationRequest] { pending }
    func deliveredRequests() async -> [UNNotificationRequest] { delivered }
    func add(_ request: UNNotificationRequest) async throws {
        if let beforeAdd { await beforeAdd(request) }
        if failAdd { throw CocoaError(.fileWriteUnknown) }
        additions.append(request)
        pending.removeAll { $0.identifier == request.identifier }
        pending.append(request)
    }
    func removePending(identifiers: [String]) { pending.removeAll { identifiers.contains($0.identifier) } }
    func removeDelivered(identifiers: [String]) { delivered.removeAll { identifiers.contains($0.identifier) } }
}

@MainActor private final class NotificationTestSignal {
    private var sent = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if sent { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func send() {
        sent = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

@Test @MainActor func remoteOwnershipHandoffWaitsUntilAnOlderLocalAddIsRemoved() async throws {
    let fixture = try await SchedulerFixture.make()
    let adding = NotificationTestSignal(), release = NotificationTestSignal(), handoffStarted = NotificationTestSignal()
    fixture.center.beforeAdd = { _ in adding.send(); await release.wait() }
    let local = Task { try await fixture.scheduler.reconcile([fixture.reminder], validReminders: [fixture.reminder]) }
    await adding.wait()
    var handoffCompleted = false
    let handoff = Task {
        handoffStarted.send()
        try await fixture.scheduler.reconcile([fixture.reminder], validReminders: [fixture.reminder], remoteOwnedIDs: [fixture.reminder.id])
        handoffCompleted = true
    }
    await handoffStarted.wait()
    #expect(!handoffCompleted, "The relay must not upload while an older local add is in flight")
    release.send()
    try await local.value
    try await handoff.value
    #expect(handoffCompleted)
    #expect(!fixture.center.pending.contains { $0.identifier == fixture.reminder.id })
}

@Test @MainActor func failedLocalReconciliationDoesNotAuthorizeACoalescedOwnershipHandoff() async throws {
    let fixture = try await SchedulerFixture.make()
    let adding = NotificationTestSignal(), release = NotificationTestSignal(), handoffStarted = NotificationTestSignal()
    fixture.center.beforeAdd = { _ in adding.send(); await release.wait() }
    fixture.center.failAdd = true
    let local = Task {
        do { try await fixture.scheduler.reconcile([fixture.reminder], validReminders: [fixture.reminder]); return false }
        catch { return true }
    }
    await adding.wait()
    let handoff = Task {
        handoffStarted.send()
        do {
            try await fixture.scheduler.reconcile([fixture.reminder], validReminders: [fixture.reminder], remoteOwnedIDs: [fixture.reminder.id])
            return false
        } catch { return true }
    }
    await handoffStarted.wait()
    release.send()
    #expect(await local.value)
    #expect(await handoff.value)
}

@MainActor private struct SchedulerFixture {
    let repository: CalendarRepository
    let center: FakeNotificationCenter
    let scheduler: NotificationScheduler
    let source: CalendarSource
    let event: CalendarEvent
    let reminder: PlannedReminder

    static func make() async throws -> Self {
        let repository = try CalendarRepository(path: ":memory:")
        let account = CalendarAccount(subject: "notification-fixture", email: "fixture@example.invalid", scopes: [GoogleScope.events])
        try await repository.connect(account)
        let source = CalendarSource(key: CalendarKey(account: account.id, calendarID: "fixture-calendar"), title: "Fixture calendar", role: "owner")
        try await repository.reconcileCalendars([source], account: account.id, generation: account.generation)
        let now = Date()
        let start = now.addingTimeInterval(3600)
        var fields = EventTime.timed(start: start, end: start.addingTimeInterval(1800), startZone: "UTC", endZone: "UTC").providerFields
        fields["id"] = .string("fixture-event")
        fields["summary"] = .string("Private event title")
        let event = CalendarEvent(key: EventKey(calendar: source.key, eventID: "fixture-event"), raw: fields)
        try await repository.stage([event], run: "initial", source: source)
        try await repository.publish(run: "initial", source: source, token: "fixture-token")
        var preferences = Preferences()
        preferences.notifications = true
        try await repository.setPreferences(preferences)
        let reminder = try #require(ReminderPlanner.plan(events: [event], calendars: [source], preferences: preferences, now: now).first)
        let center = FakeNotificationCenter()
        let scheduler = NotificationScheduler(repository: repository, center: center)
        return Self(repository: repository, center: center, scheduler: scheduler, source: source, event: event, reminder: reminder)
    }

    func request(identifier: String? = nil, origin: String? = nil) throws -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.source
        content.userInfo = ["event": try JSONEncoder().encode(reminder.event).base64EncodedString(), "origin": origin ?? reminder.id]
        return UNNotificationRequest(identifier: identifier ?? reminder.id, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false))
    }

    func cancelEvent() async throws {
        var cancelled = event
        cancelled.raw["status"] = .string("cancelled")
        try await repository.stage([cancelled], run: "cancelled", source: source)
        try await repository.publish(run: "cancelled", source: source, token: "fixture-token-2")
    }
}

@Test @MainActor func remoteOwnershipRemovesLocalSchedulesButPreservesValidSnoozes() async throws {
    let fixture = try await SchedulerFixture.make()
    let snooze = try fixture.request(identifier: "dayfold.snooze.fixture")
    let immediate = try fixture.request(identifier: "dayfold.relay.fixture")
    let stale = try fixture.request(identifier: "dayfold.snooze.stale", origin: "old-schedule")
    let unrelated = UNNotificationRequest(identifier: "another-feature", content: UNMutableNotificationContent(), trigger: nil)
    fixture.center.pending = [try fixture.request(), snooze, immediate, stale, unrelated]
    try await fixture.scheduler.reconcile([fixture.reminder], validReminders: [fixture.reminder], remoteOwnedIDs: [fixture.reminder.id])
    #expect(Set(fixture.center.pending.map(\.identifier)) == [snooze.identifier, immediate.identifier, unrelated.identifier])
    #expect(try await fixture.repository.ledger().isEmpty)
    try await fixture.scheduler.reconcile([fixture.reminder], validReminders: [fixture.reminder])
    #expect(fixture.center.pending.contains { $0.identifier == fixture.reminder.id })
    try await fixture.scheduler.reconcile([], validReminders: [], remoteOwnedIDs: [fixture.reminder.id])
    #expect(fixture.center.pending.map(\.identifier) == [unrelated.identifier])
}

@Test @MainActor func relayDeliveryUsesStableIdentityAndDoesNotReAddPendingOrDeliveredAlerts() async throws {
    let fixture = try await SchedulerFixture.make()
    let id = UUID()
    #expect(fixture.center.configured)
    #expect(await fixture.scheduler.deliverRelayReminder(reminder: fixture.reminder, notificationID: id))
    let request = try #require(fixture.center.pending.first)
    #expect(request.identifier == "dayfold.relay." + id.uuidString.lowercased())
    #expect(request.trigger == nil)
    #expect(request.content.userInfo["origin"] as? String == fixture.reminder.id)
    #expect(request.content.title == fixture.reminder.title)
    #expect(await fixture.scheduler.deliverRelayReminder(reminder: fixture.reminder, notificationID: id))
    #expect(fixture.center.additions.count == 1)
    fixture.center.pending = []
    fixture.center.delivered = [request]
    #expect(await fixture.scheduler.deliverRelayReminder(reminder: fixture.reminder, notificationID: id))
    #expect(fixture.center.additions.count == 1)
    fixture.center.status = .denied
    #expect(await !fixture.scheduler.deliverRelayReminder(reminder: fixture.reminder, notificationID: UUID()))
    #expect(fixture.center.additions.count == 1)
}

@Test @MainActor func relayDeliveryChecksCurrentPrivacyCancellationAndNotificationPreferences() async throws {
    let fixture = try await SchedulerFixture.make()
    var preferences = try await fixture.repository.preferences()
    preferences.privateNotifications = true
    try await fixture.repository.setPreferences(preferences)
    #expect(await fixture.scheduler.deliverRelayReminder(reminder: fixture.reminder, notificationID: UUID()))
    #expect(fixture.center.additions.last?.content.title == "Busy event")
    #expect(fixture.center.additions.last?.content.body == "Dayfold reminder")
    preferences.notifications = false
    try await fixture.repository.setPreferences(preferences)
    #expect(await !fixture.scheduler.deliverRelayReminder(reminder: fixture.reminder, notificationID: UUID()))
    preferences.notifications = true
    try await fixture.repository.setPreferences(preferences)
    try await fixture.cancelEvent()
    #expect(await !fixture.scheduler.deliverRelayReminder(reminder: fixture.reminder, notificationID: UUID()))
    #expect(fixture.center.additions.count == 1)
}

@Test @MainActor func localForegroundDeliveryRejectsStalePrivateOrRemotelyOwnedRequests() async throws {
    let fixture = try await SchedulerFixture.make()
    let request = try fixture.request()
    #expect(await fixture.scheduler.presentationOptions(for: request) == [.banner, .sound])
    try await fixture.scheduler.reconcile([fixture.reminder], validReminders: [fixture.reminder], remoteOwnedIDs: [fixture.reminder.id])
    #expect(await fixture.scheduler.presentationOptions(for: request).isEmpty)
    #expect(try await fixture.scheduler.presentationOptions(for: fixture.request(identifier: "dayfold.snooze.fixture")) == [.banner, .sound])
    var preferences = try await fixture.repository.preferences()
    preferences.privateNotifications = true
    try await fixture.repository.setPreferences(preferences)
    #expect(try await fixture.scheduler.presentationOptions(for: fixture.request(identifier: "dayfold.snooze.fixture")).isEmpty)
    try await fixture.cancelEvent()
    #expect(await fixture.scheduler.presentationOptions(for: request).isEmpty)
}

@MainActor private final class RemoteCallbackRecorder {
    var presentations: [RemotePushPayload] = []
    var actions: [(RemotePushPayload, String)] = []
    var allow = false
}

@Test @MainActor func foregroundRemoteHooksFailClosedAndRouteOnlyValidatedPayloads() async throws {
    let fixture = try await SchedulerFixture.make()
    let recorder = RemoteCallbackRecorder()
    let content = UNMutableNotificationContent()
    content.userInfo = remoteInfo()
    let request = UNNotificationRequest(identifier: "apns-fixture", content: content, trigger: nil)
    #expect(await fixture.scheduler.presentationOptions(for: request).isEmpty)
    fixture.scheduler.remoteWillPresent = { payload in
        recorder.presentations.append(payload)
        return recorder.allow
    }
    fixture.scheduler.remoteDidReceive = { payload, action in recorder.actions.append((payload, action)) }
    #expect(await fixture.scheduler.presentationOptions(for: request).isEmpty)
    recorder.allow = true
    #expect(await fixture.scheduler.presentationOptions(for: request) == [.banner, .sound])
    await fixture.scheduler.handleResponse(request: request, action: UNNotificationDefaultActionIdentifier)
    #expect(recorder.actions.count == 1)
    #expect(recorder.actions.first?.0.revision == 4)
    #expect(recorder.actions.first?.1 == UNNotificationDefaultActionIdentifier)
    content.userInfo = remoteInfo(kind: "calendar_changed", revision: NSNull())
    let hint = UNNotificationRequest(identifier: "hint", content: content, trigger: nil)
    #expect(await fixture.scheduler.presentationOptions(for: hint).isEmpty)
    content.userInfo["revision"] = true
    let invalid = UNNotificationRequest(identifier: "invalid", content: content, trigger: nil)
    let calls = recorder.presentations.count
    #expect(await fixture.scheduler.presentationOptions(for: invalid).isEmpty)
    await fixture.scheduler.handleResponse(request: invalid, action: UNNotificationDefaultActionIdentifier)
    #expect(recorder.presentations.count == calls && recorder.actions.count == 1)
}
