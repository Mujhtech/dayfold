import Foundation
import Testing
@testable import CalendarCore

private let coordinatorNow = Date(timeIntervalSince1970: 1_800_000_000)

private actor CoordinatorClient: RelayClientProtocol {
    let repository: CalendarRepository
    var apnsEnabled = false
    var notificationPages: [Result<RelayNotificationPage, RelayClientError>] = []
    var cursorValue = RelayCursor(floor: 0, current: 0)
    var acknowledged: [Int64] = []
    var acknowledgementStates: [RelayState] = []
    var acknowledgementFailures = 0
    var puts: [(UUID, Int64)] = []
    var putStates: [RelayState] = []
    var putFailures = 0
    var deletes: [(UUID, Int64)] = []
    var deleteFailures = 0
    var reservations: [UUID] = []
    var activations: [UUID] = []
    var activationFailures = 0
    var revokedChannels: [UUID] = []
    var claimed: [UUID] = []
    var claimAllowed = true
    var cursorCalls = 0
    var pageCursors: [Int64] = []
    var revoked = false

    init(repository: CalendarRepository) { self.repository = repository }
    func failAcknowledgements(_ count: Int) { acknowledgementFailures = count }
    func failPuts(_ count: Int) { putFailures = count }
    func failDeletes(_ count: Int) { deleteFailures = count }
    func failActivations(_ count: Int) { activationFailures = count }
    func setClaimAllowed(_ allowed: Bool) { claimAllowed = allowed }
    func setPages(_ pages: [Result<RelayNotificationPage, RelayClientError>]) { notificationPages = pages }
    func setCursor(_ cursor: RelayCursor) { cursorValue = cursor }

    func capabilities() -> RelayCapabilities { RelayCapabilities(apnsEnabled: apnsEnabled) }
    func cursor() -> RelayCursor { cursorCalls += 1; return cursorValue }
    func notifications(after: Int64) throws -> RelayNotificationPage {
        pageCursors.append(after)
        if !notificationPages.isEmpty { return try notificationPages.removeFirst().get() }
        return RelayNotificationPage(notifications: [], cursorFloor: 0, latestSequence: max(after, cursorValue.current))
    }
    func acknowledge(sequence: Int64) async throws {
        acknowledged.append(sequence)
        acknowledgementStates.append(try await repository.relayState())
        if acknowledgementFailures > 0 { acknowledgementFailures -= 1; throw RelayClientError.transport }
    }
    func claimReminder(notificationID: UUID) -> Bool {
        claimed.append(notificationID)
        return claimAllowed
    }
    func reserveChannel(scopeID: UUID, expiresAt: Date) -> RelayChannelReservation {
        let id = UUID()
        reservations.append(id)
        return RelayChannelReservation(id: id, token: String(repeating: "a", count: 64),
                                       address: URL(string: "https://relay.example.test/v1/webhooks/google")!, expiresAt: expiresAt)
    }
    func activateChannel(id: UUID, resourceID: String, expiresAt: Date) throws {
        activations.append(id)
        if activationFailures > 0 { activationFailures -= 1; throw RelayClientError.transport }
    }
    func revokeChannel(id: UUID) { revokedChannels.append(id) }
    func putReminder(id: UUID, revision: Int64, dueAt: Date, expiresAt: Date) async throws {
        puts.append((id, revision))
        putStates.append(try await repository.relayState())
        if putFailures > 0 { putFailures -= 1; throw RelayClientError.transport }
    }
    func deleteReminder(id: UUID, revision: Int64) throws {
        deletes.append((id, revision))
        if deleteFailures > 0 { deleteFailures -= 1; throw RelayClientError.transport }
    }
    func registerPush(token: String, environment: RelayPushEnvironment) {}
    func revokeDevice() { revoked = true }
    nonisolated func events(after: Int64) -> AsyncThrowingStream<RelayStreamEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private actor CoordinatorWatcher: GoogleCalendarWatching {
    var created: [UUID] = []
    var stopped: [UUID] = []
    func watchEvents(source: CalendarSource, channelID: UUID, token: String, address: URL, expiresAt: Date) -> GoogleWatchChannel {
        created.append(channelID)
        return GoogleWatchChannel(id: channelID, resourceID: "fixture-events-resource", expiresAt: expiresAt)
    }
    func watchCalendarList(account: AccountID, channelID: UUID, token: String, address: URL, expiresAt: Date) -> GoogleWatchChannel {
        created.append(channelID)
        return GoogleWatchChannel(id: channelID, resourceID: "fixture-list-resource", expiresAt: expiresAt)
    }
    func stopChannel(account: AccountID, channelID: UUID, resourceID: String) { stopped.append(channelID) }
}

private actor CoordinatorObserver {
    let repository: CalendarRepository
    var refreshes: [Set<RelayScope>?] = []
    var refreshStates: [RelayState] = []
    var ownerships: [Set<String>] = []
    var delivered: [UUID] = []
    var refreshFailures = 0
    var deliveryAllowed = true
    var reentry: (@Sendable () async -> Void)?

    init(repository: CalendarRepository) { self.repository = repository }
    func failRefreshes(_ count: Int) { refreshFailures = count }
    func setDeliveryAllowed(_ allowed: Bool) { deliveryAllowed = allowed }
    func setReentry(_ action: @escaping @Sendable () async -> Void) { reentry = action }
    func refresh(_ scopes: Set<RelayScope>?) async throws {
        refreshes.append(scopes)
        refreshStates.append(try await repository.relayState())
        if let reentry { await reentry() }
        if refreshFailures > 0 { refreshFailures -= 1; throw RelayProcessingError.syncIncomplete }
    }
    func applyOwnership(_ identifiers: Set<String>) { ownerships.append(identifiers) }
    func deliver(_ reminder: PlannedReminder, id: UUID) -> Bool {
        delivered.append(id)
        return deliveryAllowed
    }
    func callbacks() -> RelayCallbacks {
        RelayCallbacks(refresh: { try await self.refresh($0) },
                       applyOwnership: { await self.applyOwnership($0) },
                       deliverReminder: { await self.deliver($0, id: $1) },
                       status: { _ in })
    }
}

private struct CoordinatorFixture: Sendable {
    let repository: CalendarRepository
    let client: CoordinatorClient
    let observer: CoordinatorObserver
    let configuration: RelayConfiguration
    let account: CalendarAccount
    let source: CalendarSource
    let reminder: PlannedReminder

    static func make() throws -> Self {
        let repository = try CalendarRepository(path: ":memory:")
        var account = CalendarAccount(subject: "relay-fixture", email: "relay@example.invalid", scopes: [GoogleScope.events])
        account.status = .healthy
        let source = CalendarSource(key: CalendarKey(account: account.id, calendarID: "fixture-calendar"), title: "Fixture", role: "owner")
        let reminder = PlannedReminder(id: "dayfold.fixture", event: EventKey(calendar: source.key, eventID: "fixture-event"),
                                       title: "Local title", source: "Local source", fire: coordinatorNow.addingTimeInterval(120))
        return Self(repository: repository, client: CoordinatorClient(repository: repository),
                    observer: CoordinatorObserver(repository: repository),
                    configuration: RelayConfiguration(origin: URL(string: "https://relay.example.test")!, deviceID: UUID()),
                    account: account, source: source, reminder: reminder)
    }

    func input(desired: [PlannedReminder] = [], valid: [PlannedReminder] = [], authorized: Bool = true) -> RelayReconciliation {
        RelayReconciliation(accounts: [account], calendars: [source], desired: desired, valid: valid,
                            remindersEnabled: true, notificationAuthorization: authorized)
    }

    var scope: RelayScope { RelayScope(account: account.id, calendar: source.key) }

    func hint(sequence: Int64, scopeID: UUID) -> RelayNotification {
        RelayNotification(sequence: sequence, id: UUID(), kind: .calendarChanged, subjectID: scopeID, revision: nil,
                          createdAt: coordinatorNow, expiresAt: coordinatorNow.addingTimeInterval(3_600))
    }

    func notice(sequence: Int64, remoteID: UUID, id: UUID = UUID()) -> RelayNotification {
        RelayNotification(sequence: sequence, id: id, kind: .reminderDue, subjectID: remoteID, revision: 1,
                          createdAt: coordinatorNow, expiresAt: coordinatorNow.addingTimeInterval(600))
    }

    func coordinator(watcher: (any GoogleCalendarWatching)? = nil, input: RelayReconciliation? = nil) async throws -> RelayCoordinator {
        let policy = RelayPolicy(handoffLead: 0, allowSSEOnlyReminders: true, automaticTasks: false, now: { coordinatorNow })
        let coordinator = RelayCoordinator(repository: repository, client: client, watcher: watcher,
                                           configuration: configuration, callbacks: await observer.callbacks(), policy: policy)
        await coordinator.update(input ?? self.input())
        try await coordinator.start()
        return coordinator
    }

    func seedWatch(activated: Bool = true) async throws -> RelayWatchState {
        let watch = RelayWatchState(scopeID: UUID(), scope: scope, channelID: UUID(), resourceID: "existing-resource",
                                    expiresAt: coordinatorNow.addingTimeInterval(86_400), activated: activated)
        var state = RelayState(configuration: configuration)
        state.watches = [watch]
        try await repository.saveRelayState(state)
        return watch
    }

    func seedReminder() async throws -> RelayReminderState {
        var dueReminder = reminder
        dueReminder.fire = coordinatorNow.addingTimeInterval(-5)
        let value = RelayReminderState(remoteID: UUID(), reminder: dueReminder, uploadedRevision: 1)
        var state = RelayState(configuration: configuration)
        state.reminders[dueReminder.id] = value
        try await repository.saveRelayState(state)
        return value
    }
}

@Test func relayCoordinatorPersistsCalendarWorkBeforeAcknowledgementAndRecoversFailedRefreshAfterRestart() async throws {
    let fixture = try CoordinatorFixture.make()
    let watch = try await fixture.seedWatch()
    let coordinator = try await fixture.coordinator()
    try await coordinator.consume(.notification(fixture.hint(sequence: 4, scopeID: watch.scopeID)))
    let atAcknowledgement = try #require(await fixture.client.acknowledgementStates.first)
    #expect(atAcknowledgement.cursor == 4 && atAcknowledgement.pendingSync == [fixture.scope])
    await fixture.observer.failRefreshes(1)
    await #expect(throws: (any Error).self) { try await coordinator.maintainNow() }
    let pending = try await fixture.repository.relayState()
    #expect(pending.cursor == 4 && pending.acknowledgedCursor == 4)
    #expect(pending.pendingSync == [fixture.scope])
    let atRefresh = try #require(await fixture.observer.refreshStates.first)
    #expect(atRefresh.cursor == 4 && atRefresh.pendingSync == [fixture.scope])
    #expect(await fixture.client.acknowledged == [4])

    await coordinator.stop()
    let restarted = try await fixture.coordinator()
    try await restarted.maintainNow()
    let recovered = try await fixture.repository.relayState()
    #expect(recovered.pendingSync.isEmpty && recovered.acknowledgedCursor == 4)
    #expect(await fixture.observer.refreshes.count == 2)
    #expect(await fixture.client.acknowledged.last == 4)
    await restarted.stop()
}

@Test func relayCoordinatorRetriesAcknowledgementWithoutLosingOrRepeatingCalendarRefresh() async throws {
    let fixture = try CoordinatorFixture.make()
    let watch = try await fixture.seedWatch()
    let coordinator = try await fixture.coordinator()
    await fixture.client.failAcknowledgements(1)
    await #expect(throws: RelayClientError.transport) {
        try await coordinator.consume(.notification(fixture.hint(sequence: 1, scopeID: watch.scopeID)))
    }
    let beforeRetry = try await fixture.repository.relayState()
    #expect(beforeRetry.cursor == 1 && beforeRetry.acknowledgedCursor == 0)
    #expect(beforeRetry.pendingSync == [fixture.scope])
    let atAcknowledgement = try #require(await fixture.client.acknowledgementStates.first)
    #expect(atAcknowledgement.cursor == 1 && atAcknowledgement.pendingSync == [fixture.scope])
    try await coordinator.maintainNow()
    try await coordinator.maintainNow()
    #expect(try await fixture.repository.relayState().acknowledgedCursor == 1)
    #expect(await fixture.observer.refreshes.count == 1)
    #expect(await fixture.client.acknowledged == [1, 1])
    await coordinator.stop()
}

@Test(.timeLimit(.minutes(1)))
func relayCoordinatorResyncSnapshotsCursorBeforeRefreshAndAllowsReentrantInputUpdates() async throws {
    let fixture = try CoordinatorFixture.make()
    let watch = try await fixture.seedWatch()
    let coordinator = try await fixture.coordinator()
    await fixture.client.setCursor(RelayCursor(floor: 6, current: 10))
    await fixture.observer.setReentry { await coordinator.update(fixture.input()) }
    try await coordinator.consume(.resyncRequired)
    let duringRefresh = try #require(await fixture.observer.refreshStates.first)
    #expect(duringRefresh.pendingResyncCursor == 10)
    #expect(duringRefresh.fullSyncPending)
    #expect(await fixture.client.cursorCalls == 1)
    let reconciled = try await fixture.repository.relayState()
    #expect(reconciled.cursor == 10 && reconciled.pendingResyncCursor == nil)
    #expect(!reconciled.fullSyncPending)

    let next = fixture.hint(sequence: 11, scopeID: watch.scopeID)
    await fixture.client.setPages([.success(RelayNotificationPage(notifications: [next], cursorFloor: 6, latestSequence: 11))])
    try await coordinator.maintainNow()
    #expect(try await fixture.repository.relayState().cursor == 11)
    #expect(await fixture.client.pageCursors.first == 10)
    #expect(await fixture.observer.refreshes.count == 2)
    await coordinator.stop()
}

@Test func relayCoordinatorRetriesActivationWithoutCreatingAnotherGoogleWatch() async throws {
    let fixture = try CoordinatorFixture.make()
    let watch = try await fixture.seedWatch(activated: false)
    let watcher = CoordinatorWatcher()
    await fixture.client.failActivations(1)
    let coordinator = try await fixture.coordinator(watcher: watcher)
    try? await coordinator.maintainNow()
    let pending = try await fixture.repository.relayState()
    #expect(pending.watches.contains { $0.channelID == watch.channelID && !$0.activated })
    try await coordinator.maintainNow()
    #expect(try await fixture.repository.relayState().watches.contains { $0.channelID == watch.channelID && $0.activated })
    #expect(await fixture.client.activations == [watch.channelID, watch.channelID])
    #expect(await fixture.client.reservations.isEmpty)
    #expect(await watcher.created.isEmpty)
    await coordinator.stop()
}

@Test func relayCoordinatorOwnsReminderDurablyBeforeAnAmbiguousUploadAndRetriesSameIdentity() async throws {
    let fixture = try CoordinatorFixture.make()
    await fixture.client.failPuts(1)
    let coordinator = try await fixture.coordinator(input: fixture.input(desired: [fixture.reminder], valid: [fixture.reminder]))
    try? await coordinator.maintainNow()
    let atPut = try #require(await fixture.client.putStates.first)
    let reserved = try #require(atPut.reminders[fixture.reminder.id])
    #expect(reserved.owned && reserved.uploadedRevision == nil)
    #expect(atPut.remoteOwnedIDs == [fixture.reminder.id])
    #expect(await fixture.observer.ownerships.contains([fixture.reminder.id]))
    #expect(try await fixture.repository.relayState().remoteOwnedIDs == [fixture.reminder.id])

    try await coordinator.maintainNow()
    let uploaded = try #require(try await fixture.repository.relayState().reminders[fixture.reminder.id])
    #expect(uploaded.remoteID == reserved.remoteID && uploaded.uploadedRevision == 1)
    #expect(await fixture.client.puts.map(\.0) == [reserved.remoteID, reserved.remoteID])
    #expect(await fixture.client.puts.map(\.1) == [1, 1])
    await coordinator.stop()
}

@Test func relayCoordinatorDeclinedLocalClaimLeavesReminderPresentationToAPNs() async throws {
    let fixture = try CoordinatorFixture.make()
    let reminder = try await fixture.seedReminder()
    let coordinator = try await fixture.coordinator(input: fixture.input(valid: [reminder.reminder]))
    let notification = fixture.notice(sequence: 1, remoteID: reminder.remoteID)
    await fixture.client.setClaimAllowed(false)
    try await coordinator.consume(.notification(notification))
    #expect(await fixture.observer.delivered.isEmpty)
    #expect(await fixture.client.claimed == [notification.id])
    #expect(try await fixture.repository.relayState().delivered[notification.id] == nil)
    #expect(try await fixture.repository.relayState().cursor == 1)
    #expect(await coordinator.shouldPresentRemote(notificationID: notification.id, subjectID: reminder.remoteID, revision: 1))
    await coordinator.stop()
}

@Test func relayCoordinatorRetriesFailedLocalPresentationWithStableIdentityAndDeduplicatesReplay() async throws {
    let fixture = try CoordinatorFixture.make()
    let reminder = try await fixture.seedReminder()
    let coordinator = try await fixture.coordinator(input: fixture.input(valid: [reminder.reminder]))
    let notification = fixture.notice(sequence: 1, remoteID: reminder.remoteID)
    await fixture.observer.setDeliveryAllowed(false)
    await #expect(throws: (any Error).self) { try await coordinator.consume(.notification(notification)) }
    #expect(try await fixture.repository.relayState().delivered[notification.id] == nil)
    #expect(await fixture.client.acknowledged.isEmpty)

    await fixture.observer.setDeliveryAllowed(true)
    try await coordinator.consume(.notification(notification))
    try await coordinator.consume(.notification(notification))
    #expect(await fixture.observer.delivered == [notification.id, notification.id])
    #expect(try await fixture.repository.relayState().delivered[notification.id] != nil)
    #expect(try await fixture.repository.relayState().acknowledgedCursor == 1)
    #expect(!(await coordinator.shouldPresentRemote(notificationID: notification.id, subjectID: reminder.remoteID, revision: 1)))
    await coordinator.stop()
}

@Test func relayCoordinatorKeepsRemoteOwnershipUntilCancellationIsConfirmed() async throws {
    let fixture = try CoordinatorFixture.make()
    let reminder = try await fixture.seedReminder()
    await fixture.client.failDeletes(1)
    let coordinator = try await fixture.coordinator()
    try? await coordinator.maintainNow()
    let pending = try #require(try await fixture.repository.relayState().reminders[fixture.reminder.id])
    #expect(pending.deleted && !pending.deletionConfirmed)
    #expect(try await fixture.repository.relayState().remoteOwnedIDs == [fixture.reminder.id])
    try await coordinator.maintainNow()
    #expect(try await fixture.repository.relayState().remoteOwnedIDs.isEmpty)
    #expect(await fixture.client.deletes.map(\.0) == [reminder.remoteID, reminder.remoteID])
    #expect(await fixture.client.deletes.map(\.1) == [2, 2])
    await coordinator.stop()
}
