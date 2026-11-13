import Foundation

public struct RelayCallbacks: Sendable {
    public var refresh: @Sendable (Set<RelayScope>?) async throws -> Void
    public var applyOwnership: @Sendable (Set<String>) async throws -> Void
    public var deliverReminder: @Sendable (PlannedReminder, UUID) async -> Bool
    public var status: @Sendable (RelayConnectionStatus) async -> Void
    public init(refresh: @escaping @Sendable (Set<RelayScope>?) async throws -> Void,
                applyOwnership: @escaping @Sendable (Set<String>) async throws -> Void,
                deliverReminder: @escaping @Sendable (PlannedReminder, UUID) async -> Bool,
                status: @escaping @Sendable (RelayConnectionStatus) async -> Void) {
        self.refresh = refresh; self.applyOwnership = applyOwnership
        self.deliverReminder = deliverReminder; self.status = status
    }
}

public struct RelayPolicy: Sendable {
    public var handoffLead: TimeInterval
    public var maintenanceInterval: TimeInterval
    public var watchLifetime: TimeInterval
    public var watchRenewalLead: TimeInterval
    public var requestTimeout: TimeInterval
    public var allowSSEOnlyReminders: Bool
    public var automaticTasks: Bool
    public var now: @Sendable () -> Date
    public static let production = RelayPolicy()
    public init(handoffLead: TimeInterval = 60, maintenanceInterval: TimeInterval = 60,
                watchLifetime: TimeInterval = 86400, watchRenewalLead: TimeInterval = 3600,
                requestTimeout: TimeInterval = 30, allowSSEOnlyReminders: Bool = false,
                automaticTasks: Bool = true, now: @escaping @Sendable () -> Date = { Date() }) {
        self.handoffLead = max(0, handoffLead); self.maintenanceInterval = max(0.1, maintenanceInterval)
        self.watchLifetime = min(max(60, watchLifetime), 30 * 86400)
        self.watchRenewalLead = min(max(0, watchRenewalLead), self.watchLifetime / 2)
        self.requestTimeout = max(0.1, requestTimeout); self.allowSSEOnlyReminders = allowSSEOnlyReminders
        self.automaticTasks = automaticTasks; self.now = now
    }
}

/// Coordinates the optional relay without making it a prerequisite for local
/// calendar use. An explicit operation gate protects durable transitions across
/// suspension points; reconciliation input is a separate, reentrant mailbox.
public actor RelayCoordinator {
    private let repository: CalendarRepository
    private let client: any RelayClientProtocol
    private let watcher: (any GoogleCalendarWatching)?
    private var configuration: RelayConfiguration
    private let callbacks: RelayCallbacks
    private let policy: RelayPolicy
    private var state = RelayState()
    private var input: RelayReconciliation?
    private var inputVersion = 0
    private var started = false
    private var generation = 0
    private var operationBusy = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []
    private var streamTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var maintenanceRequested = false
    private var nextMaintenanceAt = Date.distantPast
    private var maintenanceFailures = 0
    private var authorizationFailed = false
    private var apnsEnabled = false
    private var latestPush: PushRegistration?
    private var uploadedPushGeneration: Int?
    private var pushGeneration = 0
    private var appliedOwnership: Set<String>?

    private struct PushRegistration: Sendable {
        var token: String
        var environment: RelayPushEnvironment
        var generation: Int
    }

    public init(repository: CalendarRepository, client: any RelayClientProtocol,
                watcher: (any GoogleCalendarWatching)?, configuration: RelayConfiguration,
                callbacks: RelayCallbacks, policy: RelayPolicy = .production) {
        self.repository = repository; self.client = client; self.watcher = watcher
        self.configuration = configuration; self.callbacks = callbacks; self.policy = policy
    }

    public func start() async throws {
        try await withGate { owner in
            guard !owner.started else { return }
            let stored = try await owner.repository.relayState()
            if let previous = stored.configuration,
               previous.deviceID != owner.configuration.deviceID || previous.origin != owner.configuration.origin {
                throw RelayProcessingError.configurationChanged
            }
            owner.state = stored
            try await owner.persist { $0.configuration = owner.configuration }
            try await owner.applyOwnershipLocked()
            owner.started = true; owner.generation += 1; owner.authorizationFailed = false
            owner.nextMaintenanceAt = .distantPast
        }
        guard configuration.enabled, policy.automaticTasks, streamTask == nil else { return }
        let run = generation
        streamTask = Task { [weak self] in await self?.streamLoop(run: run) }
        timerTask = Task { [weak self, policy] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(policy.maintenanceInterval)) } catch { return }
                await self?.requestMaintenance()
            }
        }
        requestMaintenance()
    }

    public func stop() async {
        started = false; generation += 1
        streamTask?.cancel(); timerTask?.cancel(); maintenanceTask?.cancel()
        streamTask = nil; timerTask = nil; maintenanceTask = nil
        // Wait for a cancelled transition to save any already-established intent.
        try? await withGate { _ in }
    }

    /// Never waits on the operation gate. In particular, a refresh callback can
    /// reload AppModel and call update while the initiating transition is suspended.
    public func update(_ input: RelayReconciliation) async {
        if self.input != input { inputVersion += 1 }
        self.input = input
        requestMaintenance()
    }

    public func maintainNow() async throws {
        maintenanceRequested = false
        do {
            try await withGate { owner in
                guard owner.started, owner.configuration.enabled else { return }
                try await owner.maintainLocked()
            }
        } catch {
            await report(error)
            throw error
        }
    }

    public func registerPush(token: String, environment: RelayPushEnvironment) async throws {
        pushGeneration += 1
        let registration = PushRegistration(token: token, environment: environment, generation: pushGeneration)
        latestPush = registration // Retain only the latest callback in memory on failure.
        do {
            try await withGate { owner in
                try await owner.call { [client = owner.client] in try await client.registerPush(token: token, environment: environment) }
                if owner.latestPush?.generation == registration.generation {
                    owner.uploadedPushGeneration = registration.generation
                }
            }
            requestMaintenance()
        } catch { requestMaintenance(); await report(error); throw error }
    }

    public func ownedReminderIDs() async -> Set<String> { state.remoteOwnedIDs }

    public func shouldPresentRemote(notificationID: UUID, subjectID: UUID, revision: Int64) async -> Bool {
        do {
            return try await withGate { owner in
                guard owner.started, owner.state.delivered[notificationID] == nil,
                      owner.validReminder(remoteID: subjectID, revision: revision) != nil else { return false }
                let now = owner.policy.now()
                try await owner.persist { Self.recordDelivered(notificationID, at: now, in: &$0) }
                return true
            }
        } catch { return false }
    }

    public func eventForRemote(subjectID: UUID) async -> EventKey? {
        state.reminders.values.first { $0.remoteID == subjectID }?.reminder.event
    }

    public func handleRemoteHint(subjectID: UUID) async {
        do {
            try await withGate { owner in
                guard owner.started else { return }
                let scope = owner.state.watches.first { $0.scopeID == subjectID }?.scope
                try await owner.persist {
                    if let scope { $0.pendingSync.insert(scope) } else { $0.fullSyncPending = true }
                }
            }
            requestMaintenance()
        } catch { await report(error) }
    }

    public func setRemindersEnabled(_ enabled: Bool) async throws {
        try await withGate { owner in
            var configuration = owner.configuration; configuration.reminders = enabled
            try await owner.persist { $0.configuration = configuration }
            owner.configuration = configuration
            if !enabled { try await owner.reconcileRemindersLocked() }
        }
        requestMaintenance()
    }

    public func removeAccount(_ account: AccountID) async throws {
        try await withGate { owner in
            try await owner.persist { value in
                value.removingAccounts.insert(account)
                for index in value.watches.indices where value.watches[index].scope.account == account {
                    value.watches[index].retired = true
                }
                for key in value.reminders.keys where value.reminders[key]?.reminder.event.calendar.account == account {
                    Self.markDeleted(key, in: &value)
                }
            }
            try await owner.cleanWatchesLocked()
            try await owner.deleteRemindersLocked()
            try await owner.applyOwnershipLocked()
        }
    }

    public func disconnect() async throws {
        try await withGate { owner in
            try await owner.call { [client = owner.client] in try await client.revokeDevice() }
            try await owner.clearRevokedDeviceLocked()
        }
    }

    /// Only call after the server explicitly confirmed device revocation or a
    /// same-key re-enrollment proved that the old device has been revoked.
    public func clearAfterRevocation() async throws {
        try await withGate { owner in try await owner.clearRevokedDeviceLocked() }
    }

    private func clearRevokedDeviceLocked() async throws {
            let watches = self.state.watches
            self.started = false; self.generation += 1
            self.streamTask?.cancel(); self.timerTask?.cancel(); self.maintenanceTask?.cancel()
            self.streamTask = nil; self.timerTask = nil; self.maintenanceTask = nil
            try await self.callbacks.applyOwnership([])
            try await self.repository.clearRelayState()
            self.state = RelayState(); self.appliedOwnership = []
            await self.stopGoogleWatches(watches)
            await self.callbacks.status(.init(message: "Real-time notifications disconnected."))
    }

    /// Shared by the SSE loop and deterministic protocol tests. Polling uses the
    /// same locked processing path, so two arrival paths cannot race cursor writes.
    func consume(_ event: RelayStreamEvent) async throws {
        defer { requestMaintenance() }
        try await withGate { owner in
            guard owner.started else { throw RelayClientError.cancelled }
            switch event {
            case .resyncRequired: try await owner.resynchronizeLocked()
            case .notification(let notification): try await owner.consumeLocked(notification)
            }
        }
    }

    private func maintainLocked() async throws {
        var failure: Error?
        do { try await retryPushLocked() } catch { if isUnauthorized(error) { throw error }; failure = error }
        do {
            let capabilities = try await call { [client] in try await client.capabilities() }
            apnsEnabled = capabilities.apnsEnabled
        } catch { apnsEnabled = false; if isUnauthorized(error) { throw error }; failure = failure ?? error }
        var attemptedRefresh = false
        if state.pendingResyncCursor != nil {
            // Do not acknowledge later hints while a captured resync boundary is
            // unfinished: retention must not overtake that replay position.
            attemptedRefresh = true
            do { try await refreshPendingLocked() } catch { failure = failure ?? error }
        } else {
            do {
                let after = state.cursor
                let page = try await call { [client] in try await client.notifications(after: after) }
                for notification in page.notifications { try await consumeLocked(notification) }
            } catch {
                if needsResync(error) {
                    attemptedRefresh = true
                    do { try await resynchronizeLocked() } catch { failure = failure ?? error }
                } else { if isUnauthorized(error) { throw error }; failure = failure ?? error }
            }
        }
        if !attemptedRefresh { do { try await refreshPendingLocked() } catch { failure = failure ?? error } }
        if input != nil {
            do { try await reconcileWatchesLocked() } catch { if isUnauthorized(error) { throw error }; failure = failure ?? error }
            do { try await reconcileRemindersLocked() } catch { if isUnauthorized(error) { throw error }; failure = failure ?? error }
        }
        do { try await pruneLocked(); try await acknowledgeLocked() } catch { if isUnauthorized(error) { throw error }; failure = failure ?? error }
        if let failure { throw failure }
        await callbacks.status(.init(connected: true, message: "Real-time notifications connected.", apnsEnabled: apnsEnabled))
    }

    private func retryPushLocked() async throws {
        guard let registration = latestPush, uploadedPushGeneration != registration.generation else { return }
        try await call { [client] in try await client.registerPush(token: registration.token, environment: registration.environment) }
        if latestPush?.generation == registration.generation { uploadedPushGeneration = registration.generation }
    }

    private func consumeLocked(_ notification: RelayNotification) async throws {
        try notification.validate()
        if state.pendingResyncCursor != nil { try await refreshPendingLocked(); try await acknowledgeLocked() }
        guard notification.sequence > state.cursor else { try await acknowledgeLocked(); return }
        switch notification.kind {
        case .calendarChanged:
            let scope = state.watches.first { $0.scopeID == notification.subjectID }?.scope
            try await persist {
                if let scope { $0.pendingSync.insert(scope) } else { $0.fullSyncPending = true }
                $0.cursor = notification.sequence
            }
        case .reminderDue:
            // Before the initial snapshot exists, preserve the notification for
            // replay instead of interpreting missing local data as cancellation.
            guard input != nil else { throw RelayProcessingError.deliveryUnavailable }
            if state.delivered[notification.id] == nil,
               notification.expiresAt > policy.now(), let revision = notification.revision,
               let reminder = validReminder(remoteID: notification.subjectID, revision: revision) {
                let claimed = try await call { [client] in try await client.claimReminder(notificationID: notification.id) }
                if claimed {
                    let delivered = try await call { [callbacks] in await callbacks.deliverReminder(reminder, notification.id) }
                    guard delivered else { throw RelayProcessingError.deliveryUnavailable }
                    let now = policy.now()
                    try await persist { Self.recordDelivered(notification.id, at: now, in: &$0); $0.cursor = notification.sequence }
                } else {
                    // APNs has attempted delivery. ACK does not revoke its claim,
                    // and an arriving APNs foreground callback still may present.
                    try await persist { $0.cursor = notification.sequence }
                }
            } else { try await persist { $0.cursor = notification.sequence } }
        }
        try await acknowledgeLocked()
    }

    private func acknowledgeLocked() async throws {
        guard state.cursor > state.acknowledgedCursor else { return }
        let cursor = state.cursor
        try await call { [client] in try await client.acknowledge(sequence: cursor) }
        try await persist { $0.acknowledgedCursor = cursor }
    }

    private func resynchronizeLocked() async throws {
        if state.pendingResyncCursor == nil {
            let snapshot = try await call { [client] in try await client.cursor() }
            try await persist { $0.pendingResyncCursor = snapshot.current; $0.fullSyncPending = true }
        }
        try await refreshPendingLocked()
        try await acknowledgeLocked()
    }

    private func refreshPendingLocked() async throws {
        guard state.fullSyncPending || !state.pendingSync.isEmpty || state.pendingResyncCursor != nil else { return }
        guard input != nil else { throw RelayProcessingError.syncIncomplete }
        let full = state.fullSyncPending || state.pendingResyncCursor != nil
        let scopes: Set<RelayScope>? = full ? nil : state.pendingSync
        try await call { [callbacks] in try await callbacks.refresh(scopes) }
        try await persist {
            $0.pendingSync.removeAll(); $0.fullSyncPending = false
            if let captured = $0.pendingResyncCursor {
                $0.cursor = captured; $0.acknowledgedCursor = 0; $0.pendingResyncCursor = nil
            }
        }
    }

    private enum WatchTarget: Sendable {
        case calendarList(AccountID), events(CalendarSource)
        var scope: RelayScope {
            switch self {
            case .calendarList(let account): RelayScope(account: account)
            case .events(let source): RelayScope(account: source.key.account, calendar: source.key)
            }
        }
    }

    private func watchTargets() -> [WatchTarget] {
        guard let input else { return [] }
        let blocked: Set<AccountStatus> = [.needsReconnection, .keychainUnavailable, .blockedByOrganization, .removing]
        let accounts = input.accounts.filter { !$0.isDemo && !blocked.contains($0.status) && !state.removingAccounts.contains($0.id) }
        let listScopes: Set<String> = [GoogleScope.calendarList, "https://www.googleapis.com/auth/calendar.calendarlist", "https://www.googleapis.com/auth/calendar", "https://www.googleapis.com/auth/calendar.readonly"]
        let eventScopes: Set<String> = [GoogleScope.events, GoogleScope.freebusy, "https://www.googleapis.com/auth/calendar.events.readonly", "https://www.googleapis.com/auth/calendar", "https://www.googleapis.com/auth/calendar.readonly"]
        var result: [WatchTarget] = accounts.filter { !$0.scopes.isDisjoint(with: listScopes) }.map { .calendarList($0.id) }
        for source in input.calendars where source.syncEnabled && !source.deleted && (source.readable || source.freeBusyOnly) {
            if let account = accounts.first(where: { $0.id == source.key.account }), !account.scopes.isDisjoint(with: eventScopes) { result.append(.events(source)) }
        }
        return result
    }

    private func reconcileWatchesLocked() async throws {
        let targets = watchTargets()
        let desired = Set(targets.map(\.scope))
        try await persist { value in
            for index in value.watches.indices where !desired.contains(value.watches[index].scope) || value.watches[index].expiresAt <= policy.now() {
                value.watches[index].retired = true
            }
        }
        try await cleanWatchesLocked()
        guard let watcher else { return }
        var failure: Error?
        // A reservation without a resource survived an interrupted/ambiguous
        // Google request. Its secret is intentionally not on disk; revoke it
        // before creating a fresh identity. The unknown Google watch expires.
        for watch in state.watches where !watch.activated && watch.resourceID == nil {
            do { try await retireWatchLocked(watch) } catch { if isUnauthorized(error) { throw error }; failure = failure ?? error }
        }
        for watch in state.watches where !watch.activated && !watch.retired && watch.resourceID != nil {
            do { try await activateWatchLocked(watch) } catch { if isUnauthorized(error) { throw error }; failure = failure ?? error }
        }
        for target in targets {
            try Task.checkCancellation()
            let current = state.watches.filter { $0.scope == target.scope && !$0.retired }
            if current.contains(where: { !$0.activated }) { continue }
            if current.contains(where: { $0.activated && $0.expiresAt > policy.now().addingTimeInterval(policy.watchRenewalLead) }) { continue }
            do {
                let scopeID = current.first?.scopeID ?? UUID()
                let expiration = policy.now().addingTimeInterval(policy.watchLifetime)
                let reservation = try await call { [client] in try await client.reserveChannel(scopeID: scopeID, expiresAt: expiration) }
                let pending = RelayWatchState(scopeID: scopeID, scope: target.scope, channelID: reservation.id, expiresAt: reservation.expiresAt)
                try await persist { $0.watches.append(pending) }
                let created: GoogleWatchChannel
                switch target {
                case .calendarList(let account):
                    created = try await call { try await watcher.watchCalendarList(account: account, channelID: reservation.id, token: reservation.token, address: reservation.address, expiresAt: reservation.expiresAt) }
                case .events(let source):
                    created = try await call { try await watcher.watchEvents(source: source, channelID: reservation.id, token: reservation.token, address: reservation.address, expiresAt: reservation.expiresAt) }
                }
                guard created.id == reservation.id, created.expiresAt <= reservation.expiresAt, created.expiresAt > policy.now() else { throw RelayClientError.invalidResponse }
                var bound = pending; bound.resourceID = created.resourceID; bound.expiresAt = created.expiresAt
                try await persist { value in
                    if let index = value.watches.firstIndex(where: { $0.channelID == bound.channelID }) { value.watches[index] = bound }
                }
                try await activateWatchLocked(bound)
            } catch { if isUnauthorized(error) { throw error }; failure = failure ?? error }
        }
        do { try await cleanWatchesLocked() } catch { failure = failure ?? error }
        if let failure { throw failure }
    }

    private func activateWatchLocked(_ watch: RelayWatchState) async throws {
        guard let resource = watch.resourceID else { return }
        try await call { [client] in try await client.activateChannel(id: watch.channelID, resourceID: resource, expiresAt: watch.expiresAt) }
        try await persist { value in
            for index in value.watches.indices where value.watches[index].scope == watch.scope {
                if value.watches[index].channelID == watch.channelID { value.watches[index].activated = true }
                else { value.watches[index].retired = true }
            }
        }
    }

    private func cleanWatchesLocked() async throws {
        var failure: Error?
        for watch in state.watches where watch.retired || watch.expiresAt <= policy.now() {
            do { try await retireWatchLocked(watch) } catch { if isUnauthorized(error) { throw error }; failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    private func retireWatchLocked(_ watch: RelayWatchState) async throws {
        do { try await call { [client] in try await client.revokeChannel(id: watch.channelID) } }
        catch RelayClientError.rejected(status: 404) { /* Already removed. */ }
        try await persist { $0.watches.removeAll { $0.channelID == watch.channelID } }
        await stopGoogleWatches([watch])
    }

    private func stopGoogleWatches(_ watches: [RelayWatchState]) async {
        guard let watcher else { return }
        let timeout = min(policy.requestTimeout, 5)
        await withTaskGroup(of: Void.self) { group in
            for watch in watches {
                guard let resource = watch.resourceID else { continue }
                group.addTask {
                    _ = try? await relayDeadline(timeout) { try await watcher.stopChannel(account: watch.scope.account, channelID: watch.channelID, resourceID: resource) }
                }
            }
        }
    }

    private func reconcileRemindersLocked() async throws {
        let version = inputVersion
        let now = policy.now()
        let allowed = configuration.reminders && input?.remindersEnabled == true && input?.notificationAuthorization == true
        let valid = Dictionary((input?.valid ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        try await persist { value in
            for key in value.reminders.keys {
                guard var reminder = value.reminders[key] else { continue }
                if reminder.expiresAt <= now {
                    reminder.owned = false; reminder.deleted = true; reminder.deletionConfirmed = true
                    value.reminders[key] = reminder
                } else if !allowed || valid[key] == nil || value.removingAccounts.contains(reminder.reminder.event.calendar.account)
                            || (reminder.uploadedRevision != reminder.revision && reminder.reminder.fire < now.addingTimeInterval(-60)) {
                    Self.markDeleted(key, in: &value)
                } else if let fresh = valid[key], reminder.reminder != fresh, !reminder.deleted {
                    if reminder.reminder.fire != fresh.fire { reminder.revision += 1 }
                    reminder.reminder = fresh; value.reminders[key] = reminder
                }
            }
        }
        var failure: Error?
        do { try await deleteRemindersLocked() } catch { if isUnauthorized(error) { throw error }; failure = error }
        // Input updates are deliberately reentrant. If a reload changed the
        // schedule or permission while cancellation awaited the network, let the
        // next coalesced pass reconcile that snapshot before creating deliveries.
        guard version == inputVersion else { requestMaintenance(); if let failure { throw failure }; return }
        let readyForNew = allowed && (policy.allowSSEOnlyReminders || (apnsEnabled && latestPush != nil && uploadedPushGeneration == latestPush?.generation))
        if readyForNew {
            for desired in input?.desired ?? [] where desired.fire.timeIntervalSince(now) >= policy.handoffLead && desired.fire < now.addingTimeInterval(30 * 86400) && !state.removingAccounts.contains(desired.event.calendar.account) {
                guard version == inputVersion else { requestMaintenance(); break }
                if let old = state.reminders[desired.id] {
                    if old.deleted && !old.deletionConfirmed { continue }
                    if old.owned && !old.deleted { continue }
                    var replacement = old
                    replacement.reminder = desired; replacement.revision += 1; replacement.uploadedRevision = nil
                    replacement.deleted = false; replacement.deletionConfirmed = false; replacement.owned = true
                    try await persist { $0.reminders[desired.id] = replacement }
                } else {
                    try await persist { $0.reminders[desired.id] = RelayReminderState(reminder: desired) }
                }
            }
        }
        // This callback removes native pending requests before any remote PUT.
        // An ambiguous PUT retains this ownership until DELETE is confirmed.
        try await applyOwnershipLocked()
        for (key, reminder) in state.reminders where reminder.owned && !reminder.deleted && reminder.uploadedRevision != reminder.revision {
            guard version == inputVersion else { requestMaintenance(); break }
            do {
                try await call { [client] in try await client.putReminder(id: reminder.remoteID, revision: reminder.revision, dueAt: reminder.reminder.fire, expiresAt: reminder.expiresAt) }
                try await persist { $0.reminders[key]?.uploadedRevision = reminder.revision }
            } catch { if isUnauthorized(error) { throw error }; failure = failure ?? error }
        }
        if let failure { throw failure }
    }

    private static func markDeleted(_ key: String, in state: inout RelayState) {
        guard var reminder = state.reminders[key], !reminder.deleted else { return }
        reminder.revision += 1; reminder.deleted = true; reminder.deletionConfirmed = false
        state.reminders[key] = reminder
    }

    private static func recordDelivered(_ id: UUID, at now: Date, in state: inout RelayState) {
        state.delivered = state.delivered.filter { $0.value > now.addingTimeInterval(-7 * 86400) }
        state.delivered[id] = now
        if state.delivered.count > 4096 {
            let keep = Set(state.delivered.filter { $0.key != id }.sorted { $0.value > $1.value }.prefix(4095).map(\.key))
            state.delivered = state.delivered.filter { $0.key == id || keep.contains($0.key) }
        }
    }

    private func deleteRemindersLocked() async throws {
        var failure: Error?
        for (key, reminder) in state.reminders where reminder.deleted && !reminder.deletionConfirmed {
            do {
                try await call { [client] in try await client.deleteReminder(id: reminder.remoteID, revision: reminder.revision) }
                try await persist { $0.reminders[key]?.deletionConfirmed = true; $0.reminders[key]?.owned = false }
            } catch { if isUnauthorized(error) { throw error }; failure = failure ?? error }
        }
        try await applyOwnershipLocked()
        if let failure { throw failure }
    }

    private func validReminder(remoteID: UUID, revision: Int64) -> PlannedReminder? {
        guard configuration.enabled, configuration.reminders, let input,
              input.remindersEnabled, input.notificationAuthorization,
              let stored = state.reminders.values.first(where: { $0.remoteID == remoteID }),
              stored.owned, !stored.deleted, !stored.deletionConfirmed, stored.revision == revision,
              stored.expiresAt > policy.now(), !state.removingAccounts.contains(stored.reminder.event.calendar.account),
              input.valid.contains(where: { $0.id == stored.reminder.id && $0.fire == stored.reminder.fire }) else { return nil }
        return stored.reminder
    }

    private func applyOwnershipLocked() async throws {
        let owned = state.remoteOwnedIDs
        guard appliedOwnership != owned else { return }
        try await callbacks.applyOwnership(owned)
        appliedOwnership = owned
    }

    private func pruneLocked() async throws {
        let cutoff = policy.now().addingTimeInterval(-7 * 86400)
        let reminderCutoff = policy.now().addingTimeInterval(-86400)
        let accounts = Set(input?.accounts.map(\.id) ?? [])
        try await persist { value in
            value.delivered = value.delivered.filter { $0.value > cutoff }
            if value.delivered.count > 4096 {
                let keep = Set(value.delivered.sorted { $0.value > $1.value }.prefix(4096).map(\.key))
                value.delivered = value.delivered.filter { keep.contains($0.key) }
            }
            value.reminders = value.reminders.filter { !$0.value.deletionConfirmed || $0.value.reminder.fire > reminderCutoff }
            if input != nil { value.removingAccounts.formIntersection(accounts) }
        }
    }

    private func requestMaintenance() {
        maintenanceRequested = true
        guard started, configuration.enabled, policy.automaticTasks, !authorizationFailed,
              maintenanceTask == nil, policy.now() >= nextMaintenanceAt else { return }
        let run = generation
        maintenanceTask = Task { [weak self] in await self?.scheduledMaintenance(run: run) }
    }

    private func scheduledMaintenance(run: Int) async {
        while running(run), maintenanceRequested, !Task.isCancelled {
            do {
                try await maintainNow()
                maintenanceFailures = 0; nextMaintenanceAt = .distantPast
            } catch {
                if isUnauthorized(error) { authorizationFailed = true }
                maintenanceFailures += 1
                nextMaintenanceAt = policy.now().addingTimeInterval(backoff(error, failures: maintenanceFailures))
                break
            }
        }
        if generation == run { maintenanceTask = nil }
    }

    private func streamLoop(run: Int) async {
        var failures = 0
        while running(run), !Task.isCancelled, !authorizationFailed {
            do {
                let after = state.cursor
                for try await event in client.events(after: after) {
                    guard running(run), !Task.isCancelled else { return }
                    try await consume(event)
                    failures = 0
                }
            } catch {
                if Task.isCancelled || !running(run) { return }
                if isUnauthorized(error) { authorizationFailed = true; await report(error); return }
                if needsResync(error) {
                    do { try await consume(.resyncRequired); failures = 0; continue }
                    catch { await report(error) }
                } else { await report(error) }
                failures += 1
                do { try await Task.sleep(for: .seconds(backoff(error, failures: failures))) } catch { return }
                continue
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    private func running(_ run: Int) -> Bool { started && configuration.enabled && generation == run }
    private func isUnauthorized(_ error: Error) -> Bool {
        guard let error = error as? RelayClientError else { return false }
        return [.unauthorized, .reauthenticationRequired, .sessionSuperseded].contains(error)
    }
    private func needsResync(_ error: Error) -> Bool {
        guard let error = error as? RelayClientError else { return false }
        return error == .resyncRequired || error == .rejected(status: 400)
    }
    private func backoff(_ error: Error, failures: Int) -> TimeInterval {
        var minimum: TimeInterval = 0
        if let error = error as? RelayClientError {
            switch error {
            case .rateLimited(let value), .unavailable(let value): minimum = value ?? 0
            default: break
            }
        }
        return max(minimum, min(60, pow(2, Double(min(6, max(0, failures)))) + Double.random(in: 0...0.5)))
    }
    private func report(_ error: Error) async {
        let message: String
        if isUnauthorized(error) { message = "Reconnect the notification service to continue." }
        else if error is RelayProcessingError { message = "Calendar or reminder delivery is waiting to retry." }
        else { message = "Real-time notifications are temporarily unavailable; local calendar sync continues." }
        await callbacks.status(.init(message: message, apnsEnabled: apnsEnabled,
                                     deviceRevoked: (error as? RelayClientError) == .reauthenticationRequired))
    }

    private func persist(_ change: (inout RelayState) -> Void) async throws {
        var next = state; change(&next)
        guard next != state else { return }
        try await repository.saveRelayState(next)
        state = next
    }

    private func withGate<T: Sendable>(_ operation: (isolated RelayCoordinator) async throws -> T) async throws -> T {
        if operationBusy { await withCheckedContinuation { operationWaiters.append($0) } }
        else { operationBusy = true }
        defer {
            if operationWaiters.isEmpty { operationBusy = false }
            else { operationWaiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await operation(self)
    }

    private func call<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await relayDeadline(policy.requestTimeout, operation: operation)
    }
}

private func relayDeadline<T: Sendable>(_ seconds: TimeInterval,
                                       operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw RelayClientError.unavailable(retryAfter: nil)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw RelayClientError.cancelled }
        return result
    }
}
