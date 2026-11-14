import AppKit
import CalendarCore
import CalendarPlatform
import Foundation
import UserNotifications

extension AppModel {
    var allowsLocalRelay: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--allow-development-relay")
        #else
        false
        #endif
    }
    private func relayVault() throws -> RelayCredentialStore {
        if let relayCredentialStore { return relayCredentialStore }
        guard let dataDirectory else { throw RelayProcessingError.configurationChanged }
        let vault = RelayCredentialStore(namespace: dataDirectory.standardizedFileURL.path, allowLoopbackHTTP: allowsLocalRelay)
        relayCredentialStore = vault
        return vault
    }

    func configureRelayNotificationHandlers() {
        notifications?.remoteWillPresent = { [weak self] payload in
            guard let self, !self.isDemo, self.preferences.notifications,
                  payload.kind == .reminderDue, let revision = payload.revision, let relay = self.relay else { return false }
            return await relay.shouldPresentRemote(notificationID: payload.notificationID, subjectID: payload.subjectID, revision: revision)
        }
        notifications?.remoteDidReceive = { [weak self] payload, action in
            await self?.handleRelayTap(payload, action: action)
        }
    }

    func restoreRelay(generation: Int) async {
        guard generation == sessionGeneration, !isDemo, !relayRestoring, relay == nil,
              let configuration = relayConfiguration, configuration.enabled else { return }
        relayRestoring = true
        defer { if generation == sessionGeneration { relayRestoring = false } }
        do {
            let vault = try relayVault()
            let client: RelayClient
            if let origin = try await RelayAccountSession.savedOrigin(vault: vault) {
                guard origin == configuration.origin else { throw RelayClientError.invalidConfiguration }
                let session = try await RelayAccountSession.open(origin: origin, vault: vault, allowLoopbackHTTP: allowsLocalRelay)
                guard let identity = await session.identity(), identity.deviceID == configuration.deviceID,
                      generation == sessionGeneration else { throw RelayProcessingError.configurationChanged }
                relayAccountSession = session; relayAccountIdentity = identity
                client = try RelayClient(baseURL: origin, authorizer: session, allowLoopbackHTTP: allowsLocalRelay)
            } else {
                guard allowsLocalRelay, configuration.origin.scheme == "http",
                      let credentials = try await vault.load(), credentials.deviceID == configuration.deviceID,
                      credentials.origin == configuration.origin else { throw RelayClientError.unauthorized }
                client = try RelayClient(baseURL: credentials.origin, token: credentials.token, allowLoopbackHTTP: true)
            }
            guard generation == sessionGeneration else { throw RelayProcessingError.configurationChanged }
            try await installRelay(client: client, configuration: configuration, generation: generation)
        } catch {
            guard generation == sessionGeneration else { return }
            relayConnected = false; relayStatus = error.localizedDescription
        }
    }

    private func installRelay(client: any RelayClientProtocol, configuration: RelayConfiguration, generation: Int) async throws {
        guard generation == sessionGeneration, let repository else { throw RelayProcessingError.configurationChanged }
        let connectionID = UUID()
        relayConnectionID = connectionID
        let callbacks = RelayCallbacks(
            refresh: { [weak self] scopes in
                guard let self, await self.relayIsCurrent(generation, connectionID) else { throw CancellationError() }
                try await self.refreshForRelay(scopes: scopes, generation: generation, connectionID: connectionID)
            },
            applyOwnership: { [weak self] ids in
                guard let self, await self.relayIsCurrent(generation, connectionID) else { throw CancellationError() }
                try await self.applyRelayOwnership(ids, generation: generation, connectionID: connectionID)
            },
            deliverReminder: { [weak self] reminder, notificationID in
                guard let self, await self.relayIsCurrent(generation, connectionID) else { return false }
                return await self.deliverRelayReminder(reminder, notificationID: notificationID, generation: generation, connectionID: connectionID)
            },
            status: { [weak self] status in
                guard let self, await self.relayIsCurrent(generation, connectionID) else { return }
                await self.receiveRelayStatus(status, generation: generation, connectionID: connectionID)
            }
        )
        let watcher: (any GoogleCalendarWatching)? = isDemo ? nil : provider as? any GoogleCalendarWatching
        let coordinator = RelayCoordinator(repository: repository, client: client, watcher: watcher,
            configuration: configuration, callbacks: callbacks)
        relay = coordinator
        if let lastRelayInput { await coordinator.update(lastRelayInput) }
        try await coordinator.start()
        guard relayIsCurrent(generation, connectionID) else { await coordinator.stop(); throw CancellationError() }
        let owned = await coordinator.ownedReminderIDs()
        guard relayIsCurrent(generation, connectionID) else { await coordinator.stop(); throw CancellationError() }
        relayOwnedReminderIDs = owned
        registerRelayPush()
        if let apnsToken { await uploadRelayPushToken(apnsToken) }
        for hint in relayPushHints { await coordinator.handleRemoteHint(subjectID: hint) }
        relayPushHints = []
        let taps = relayPendingTaps; relayPendingTaps = []
        for (payload, action) in taps { await handleRelayTap(payload, action: action) }
    }

    func connectRelay(origin: String, deviceID: String, token: String, reminders: Bool) async throws {
        guard allowsLocalRelay, !isLoading, !isDemo, !relayConnecting, let repository, let url = URL(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "http",
              let id = UUID(uuidString: deviceID.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw RelayClientError.invalidConfiguration }
        guard relayConfiguration == nil else { throw CalendarError.invalid("Disconnect the current real-time service before replacing it.") }
        let generation = sessionGeneration
        relayConnecting = true; defer { if generation == sessionGeneration { relayConnecting = false } }
        let normalized = try RelayEndpoint.validatedOrigin(url, allowLoopbackHTTP: allowsLocalRelay)
        let bearer = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = try RelayClient(baseURL: normalized, token: bearer, allowLoopbackHTTP: allowsLocalRelay)
        _ = try await client.capabilities()
        guard generation == sessionGeneration else { throw RelayProcessingError.configurationChanged }
        let vault = try relayVault()
        try await vault.save(RelayCredentials(origin: normalized, deviceID: id, token: bearer))
        guard generation == sessionGeneration else { throw RelayProcessingError.configurationChanged }
        let configuration = RelayConfiguration(origin: normalized, deviceID: id, reminders: reminders)
        try await repository.saveRelayState(RelayState(configuration: configuration))
        guard generation == sessionGeneration else { throw RelayProcessingError.configurationChanged }
        relayConfiguration = configuration
        try await installRelay(client: client, configuration: configuration, generation: generation)
    }

    func prepareDayfoldSignIn(origin: String) async throws {
        guard !isLoading, !isDemo, !relayConnecting,
              let url = URL(string: origin.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw RelayClientError.invalidConfiguration }
        let generation = sessionGeneration
        relayConnecting = true; defer { if generation == sessionGeneration { relayConnecting = false } }
        let api = try RelayAuthenticationClient(origin: url, allowLoopbackHTTP: allowsLocalRelay)
        guard relayConfiguration == nil || relayConfiguration?.origin == api.origin else { throw RelayClientError.invalidConfiguration }
        let configuration = try await api.configuration()
        guard generation == sessionGeneration else { throw CancellationError() }
        let vault = try relayVault()
        var existing = relayAccountSession
        if existing == nil, let savedOrigin = try await RelayAccountSession.savedOrigin(vault: vault) {
            existing = try await RelayAccountSession.open(origin: savedOrigin, vault: vault, allowLoopbackHTTP: allowsLocalRelay)
        }
        guard generation == sessionGeneration else { throw CancellationError() }
        if let existing {
            let identity = await existing.identity()
            guard generation == sessionGeneration else { throw CancellationError() }
            relayAccountSession = existing; relayAccountIdentity = identity
        }
        if let previous = existing, await previous.revocationConfirmed() {
            try await finishConfirmedDayfoldSignOut(session: previous, vault: vault, generation: generation, connectionID: relayConnectionID)
            guard generation == sessionGeneration else { throw CancellationError() }
            existing = nil
        }
        if let previous = existing, previous.origin != api.origin {
            guard try await previous.discardUnissuedSetup() else {
                throw CalendarError.invalid("Finish signing in or sign out of the current Dayfold service before changing its address.")
            }
            guard generation == sessionGeneration else { throw CancellationError() }
            existing = nil; relayAccountSession = nil
        }
        let session: RelayAccountSession
        if let existing { session = existing }
        else { session = try await RelayAccountSession.open(origin: api.origin, vault: vault, allowLoopbackHTTP: allowsLocalRelay) }
        let identity = await session.identity()
        guard generation == sessionGeneration else { await session.invalidate(); throw CancellationError() }
        relayAccountSession = session; relayAccountIdentity = identity; relayAuthConfiguration = configuration
        relayIdentityProvider = configuration.issuer.absoluteString
        UserDefaults.standard.set(api.origin.absoluteString, forKey: "dayfoldAccountService")
    }

    func signInDayfold(reminders: Bool, reconnecting: Bool = false) async throws {
        guard !isLoading, !isDemo, !relayConnecting, (relayConfiguration == nil || reconnecting), let repository,
              let session = relayAccountSession, let authConfiguration = relayAuthConfiguration else { throw RelayClientError.invalidConfiguration }
        let generation = sessionGeneration
        relayConnecting = true; defer { if generation == sessionGeneration { relayConnecting = false } }
        let previousRelay = relay, previousConfiguration = relayConfiguration
        if reconnecting { await previousRelay?.stop() }
        guard generation == sessionGeneration else { throw CancellationError() }
        let authorizer = DayfoldAccountAuthorization(); relayAccountSignIn = authorizer
        let identity: RelayAccountIdentity
        let needsAuthentication = await session.needsAuthentication()
        let pendingEnrollment = await session.hasPendingEnrollment()
        if let saved = await session.identity(), !reconnecting, !needsAuthentication, !pendingEnrollment { identity = saved }
        else { identity = try await authorizer.signIn(configuration: authConfiguration, session: session, reauthenticate: reconnecting || needsAuthentication) }
        guard generation == sessionGeneration else { throw CancellationError() }
        relayAccountSignIn = nil
        let client = try RelayClient(baseURL: identity.origin, authorizer: session, allowLoopbackHTTP: allowsLocalRelay)
        _ = try await client.capabilities()
        guard generation == sessionGeneration else { throw CancellationError() }
        let configuration = RelayConfiguration(origin: identity.origin, deviceID: identity.deviceID, reminders: reminders)
        if let previousConfiguration, previousConfiguration.deviceID != identity.deviceID {
            try await previousRelay?.clearAfterRevocation()
        }
        if previousConfiguration?.deviceID == identity.deviceID {
            var state = try await repository.relayState(); state.configuration = configuration
            try await repository.saveRelayState(state)
        } else { try await repository.saveRelayState(RelayState(configuration: configuration)) }
        guard generation == sessionGeneration else { throw CancellationError() }
        relayConfiguration = configuration; relayAccountIdentity = identity
        try await installRelay(client: client, configuration: configuration, generation: generation)
        try await refreshDayfoldDevices()
    }

    func refreshDayfoldDevices() async throws {
        guard let session = relayAccountSession, relayAccountIdentity != nil else { throw RelayClientError.unauthorized }
        let generation = sessionGeneration, connectionID = relayConnectionID
        let client = try RelayClient(baseURL: session.origin, authorizer: session, allowLoopbackHTTP: allowsLocalRelay)
        let devices = try await client.accountDevices()
        guard relayIsCurrent(generation, connectionID) else { throw CancellationError() }
        relayAccountDevices = devices
    }

    func revokeDayfoldDevice(_ id: UUID) async throws {
        if id == relayAccountIdentity?.deviceID { try await disconnectRelay(); return }
        guard let session = relayAccountSession else { throw RelayClientError.unauthorized }
        let generation = sessionGeneration, connectionID = relayConnectionID
        let client = try RelayClient(baseURL: session.origin, authorizer: session, allowLoopbackHTTP: allowsLocalRelay)
        try await client.revokeAccountDevice(id)
        guard relayIsCurrent(generation, connectionID) else { throw CancellationError() }
        try await refreshDayfoldDevices()
    }

    func revokeAllDayfoldDevices(deleteAccount: Bool = false) async throws {
        guard let session = relayAccountSession else { throw RelayClientError.unauthorized }
        let generation = sessionGeneration, connectionID = relayConnectionID
        let client = try RelayClient(baseURL: session.origin, authorizer: session, allowLoopbackHTTP: allowsLocalRelay)
        do {
            if deleteAccount { try await client.deleteAccount() }
            else { try await client.revokeAllAccountDevices() }
        } catch RelayClientError.reauthenticationRequired {
            guard relayIsCurrent(generation, connectionID) else { throw CancellationError() }
            try await disconnectRelay(alreadyRevoked: true)
            throw CalendarError.unavailable(deleteAccount
                ? "This Mac is signed out, but account deletion was not confirmed. Sign in again to check your account."
                : "This Mac is signed out, but signing out every other device was not confirmed.")
        }
        guard relayIsCurrent(generation, connectionID) else { throw CancellationError() }
        try await disconnectRelay(alreadyRevoked: true)
    }

    func disconnectRelay(alreadyRevoked: Bool = false) async throws {
        guard !relayConnecting else { return }
        let generation = sessionGeneration
        relayConnecting = true; defer { if generation == sessionGeneration { relayConnecting = false } }
        let vault = try relayVault()
        var accountSession = relayAccountSession
        if accountSession == nil, let origin = try await RelayAccountSession.savedOrigin(vault: vault) {
            accountSession = try await RelayAccountSession.open(origin: origin, vault: vault, allowLoopbackHTTP: allowsLocalRelay)
            guard generation == sessionGeneration else { throw RelayProcessingError.configurationChanged }
            relayAccountSession = accountSession
        }
        guard generation == sessionGeneration else { throw RelayProcessingError.configurationChanged }
        if let accountSession {
            let confirmed = await accountSession.revocationConfirmed()
            if !alreadyRevoked && !confirmed {
                let client = try RelayClient(baseURL: accountSession.origin, authorizer: accountSession, allowLoopbackHTTP: allowsLocalRelay)
                do { try await client.revokeDevice() }
                catch RelayClientError.reauthenticationRequired { /* Key-verified terminal response. */ }
            }
            try await finishConfirmedDayfoldSignOut(session: accountSession, vault: vault, generation: generation, connectionID: relayConnectionID)
            return
        }
        if relay == nil, let relayRestoreTask { await relayRestoreTask.value }
        if relay == nil { await restoreRelay(generation: generation) }
        guard generation == sessionGeneration else { throw RelayProcessingError.configurationChanged }
        guard let relay else { throw CalendarError.unavailable("Unlock your Mac and reconnect to the service so its pending reminders can be cancelled.") }
        let connectionID = relayConnectionID
        let repository = repository
        try await relay.disconnect()
        guard relayIsCurrent(generation, connectionID) else { throw RelayProcessingError.configurationChanged }
        try await vault.delete()
        guard relayIsCurrent(generation, connectionID) else { throw RelayProcessingError.configurationChanged }
        try await repository?.clearRelayState()
        guard relayIsCurrent(generation, connectionID) else { return }
        resetRelayAccountState()
        await reload()
    }

    private func finishConfirmedDayfoldSignOut(session: RelayAccountSession, vault: RelayCredentialStore,
                                              generation: Int, connectionID: UUID) async throws {
        guard relayIsCurrent(generation, connectionID) else { throw RelayProcessingError.configurationChanged }
        let repository = repository, coordinator = relay
        try await session.confirmRevocation()
        guard relayIsCurrent(generation, connectionID) else { throw RelayProcessingError.configurationChanged }
        try await coordinator?.clearAfterRevocation()
        guard relayIsCurrent(generation, connectionID) else { throw RelayProcessingError.configurationChanged }
        // Keep the account cleanup marker until every preceding cleanup succeeds.
        try await vault.delete()
        guard relayIsCurrent(generation, connectionID) else { throw RelayProcessingError.configurationChanged }
        try await repository?.clearRelayState()
        guard relayIsCurrent(generation, connectionID) else { throw RelayProcessingError.configurationChanged }
        try await session.clear()
        guard relayIsCurrent(generation, connectionID) else { throw RelayProcessingError.configurationChanged }
        resetRelayAccountState()
        await reload()
    }

    private func resetRelayAccountState() {
        relayConnectionID = UUID(); relay = nil
        relayConfiguration = nil; relayConnected = false; relayStatus = "Not connected"
        relayAccountSession = nil; relayAccountIdentity = nil; relayAccountDevices = []; relayAuthConfiguration = nil; relayIdentityProvider = ""
        relayOwnedReminderIDs = []; relayPendingTaps = []; relayPushHints = []
    }

    func setRelayReminders(_ enabled: Bool) async throws {
        guard let relay, var configuration = relayConfiguration else { throw RelayProcessingError.configurationChanged }
        let generation = sessionGeneration, connectionID = relayConnectionID
        do { try await relay.setRemindersEnabled(enabled) }
        catch {
            // Disabling is durable even when remote cancellation must retry.
            // Reflect that intent instead of showing an enabled toggle.
            if let saved = try? await repository?.relayState(), relayIsCurrent(generation, connectionID) {
                relayConfiguration = saved.configuration
            }
            throw error
        }
        guard relayIsCurrent(generation, connectionID) else { throw RelayProcessingError.configurationChanged }
        configuration.reminders = enabled; relayConfiguration = configuration
        if enabled { registerRelayPush() }
        await reload()
    }

    func removeRelayAccount(_ account: AccountID) async throws {
        guard relayConfiguration != nil else { return }
        let generation = sessionGeneration
        if relay == nil { await relayRestoreTask?.value }
        guard generation == sessionGeneration else { throw RelayProcessingError.configurationChanged }
        if relay == nil { await restoreRelay(generation: generation) }
        guard generation == sessionGeneration else { throw RelayProcessingError.configurationChanged }
        guard let relay else {
            throw CalendarError.unavailable("Reconnect the notification service before removing this account so its remote reminders can be cancelled.")
        }
        try await relay.removeAccount(account)
    }

    private func refreshForRelay(scopes: Set<RelayScope>?, generation: Int, connectionID: UUID) async throws {
        guard relayIsCurrent(generation, connectionID), !isSleeping, let sync else { throw CancellationError() }
        try await sync.refreshFromRelay(scopes: scopes, window: visibleRange)
        guard relayIsCurrent(generation, connectionID), !isSleeping else { throw CancellationError() }
        let today = calendar.startOfDay(for: Date())
        let upcoming = DateInterval(start: today, end: calendar.date(byAdding: .day, value: 30, to: today)!)
        if upcoming != visibleRange { try await sync.refreshFromRelay(scopes: scopes, window: upcoming) }
        guard relayIsCurrent(generation, connectionID) else { throw CancellationError() }
        await reload()
    }

    private func applyRelayOwnership(_ ids: Set<String>, generation: Int, connectionID: UUID) async throws {
        guard relayIsCurrent(generation, connectionID) else { throw CancellationError() }
        relayOwnedReminderIDs = ids
        if let input = lastRelayInput {
            try await notifications?.reconcile(input.desired, validReminders: input.valid, remoteOwnedIDs: ids)
        }
    }

    private func deliverRelayReminder(_ reminder: PlannedReminder, notificationID: UUID, generation: Int, connectionID: UUID) async -> Bool {
        guard relayIsCurrent(generation, connectionID), !isDemo, preferences.notifications,
              lastRelayInput?.valid.contains(where: { $0.id == reminder.id }) == true else { return false }
        return await notifications?.deliverRelayReminder(reminder: reminder, notificationID: notificationID) ?? false
    }

    private func receiveRelayStatus(_ status: RelayConnectionStatus, generation: Int, connectionID: UUID) {
        guard relayIsCurrent(generation, connectionID) else { return }
        relayConnected = status.connected; relayStatus = status.message
        if status.deviceRevoked, relayAccountSession != nil {
            Task { [weak self] in
                guard let self, self.relayIsCurrent(generation, connectionID), !self.relayConnecting else { return }
                do {
                    try await self.disconnectRelay(alreadyRevoked: true)
                    guard generation == self.sessionGeneration else { return }
                    self.relayStatus = "Your Dayfold session ended. Sign in again to reconnect this Mac."
                } catch { if self.relayIsCurrent(generation, connectionID) { self.relayStatus = error.localizedDescription } }
            }
        }
        if !status.apnsEnabled, RemotePushRegistration.availability().environment != nil {
            relayAPNSStatus = "The service has not enabled APNs. Local reminders remain active until push is ready."
        }
    }

    func registerRelayPush() {
        guard relay != nil, !isDemo else { return }
        switch RemotePushRegistration.registerIfAvailable() {
        case .available: relayAPNSStatus = "Registering this Mac for push notifications…"
        case .unavailable(let reason): relayAPNSStatus = reason
        }
    }

    func uploadRelayPushToken(_ data: Data) async {
        apnsToken = data
        guard !isDemo, let relay, let environment = RemotePushRegistration.availability().environment else { return }
        let generation = sessionGeneration, connectionID = relayConnectionID
        do {
            try await relay.registerPush(token: RemotePushRegistration.tokenString(from: data),
                environment: environment == .sandbox ? .sandbox : .production)
            guard relayIsCurrent(generation, connectionID) else { return }
            relayAPNSStatus = "This Mac is registered for push notifications"
        } catch {
            if relayIsCurrent(generation, connectionID) {
                relayAPNSStatus = (error as? RelayClientError) == .rejected(status: 403)
                    ? "Push requires verified device delivery. Local reminders remain active."
                    : "Push registration is waiting to reconnect."
            }
        }
    }

    func receivedRelayPush(_ payload: RemotePushPayload) {
        guard payload.kind == .calendarChanged else { return }
        if let relay { Task { await relay.handleRemoteHint(subjectID: payload.subjectID) } }
        else if relayPushHints.count < 128 { relayPushHints.insert(payload.subjectID) }
    }

    func handleRelayTap(_ payload: RemotePushPayload, action: String) async {
        guard action != UNNotificationDismissActionIdentifier else { return }
        guard !isDemo, let relay else {
            if relayPendingTaps.count < 16 { relayPendingTaps.append((payload, action)) }
            return
        }
        let generation = sessionGeneration, connectionID = relayConnectionID
        let key = await relay.eventForRemote(subjectID: payload.subjectID)
        guard relayIsCurrent(generation, connectionID) else { return }
        if let key { route(to: key, join: action == "JOIN") }
        else { openCalendar?() }
    }

    func resumeRelay() async {
        guard !isDemo, !isSleeping, !isLoading else { return }
        if let relay { try? await relay.start(); registerRelayPush() }
        else { await restoreRelay(generation: sessionGeneration) }
    }

    private func relayIsCurrent(_ generation: Int, _ connectionID: UUID) -> Bool {
        generation == sessionGeneration && connectionID == relayConnectionID
    }
}
