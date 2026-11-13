import Foundation
import Testing
@testable import CalendarCore

private struct LocalRelayInstallation: Decodable {
    let deviceID: UUID
    let token: String
    let origin: URL
    enum CodingKeys: String, CodingKey { case deviceID = "device_id", token, origin }
}

private actor LocalRelaySink {
    var refreshes = 0
    var ownership: Set<String> = []
    var deliveries: [UUID] = []
    func refreshed() { refreshes += 1 }
    func own(_ ids: Set<String>) { ownership = ids }
    func deliver(_ id: UUID) -> Bool { deliveries.append(id); return true }
    func ready(_ id: String) -> Bool { refreshes >= 1 && ownership.contains(id) }
}

/// Emulates only Google's callback side against the actual local Rust API.
/// No request is ever sent to the public address returned in the reservation.
private actor LocalRelayGoogle: GoogleCalendarWatching {
    let origin: URL
    var channels: [UUID: (token: String, resource: String)] = [:]
    init(origin: URL) { self.origin = origin }
    func watchEvents(source: CalendarSource, channelID: UUID, token: String, address: URL, expiresAt: Date) async throws -> GoogleWatchChannel {
        try await create(channelID, token: token, expiresAt: expiresAt)
    }
    func watchCalendarList(account: AccountID, channelID: UUID, token: String, address: URL, expiresAt: Date) async throws -> GoogleWatchChannel {
        try await create(channelID, token: token, expiresAt: expiresAt)
    }
    func stopChannel(account: AccountID, channelID: UUID, resourceID: String) { channels[channelID] = nil }
    private func create(_ id: UUID, token: String, expiresAt: Date) async throws -> GoogleWatchChannel {
        let resource = "swift-integration-" + id.uuidString.lowercased()
        channels[id] = (token, resource)
        try await callback(id: id, token: token, resource: resource, number: 1, state: "sync")
        return GoogleWatchChannel(id: id, resourceID: resource, expiresAt: expiresAt)
    }
    func changed() async throws {
        for (id, value) in channels {
            try await callback(id: id, token: value.token, resource: value.resource, number: 2, state: "exists")
        }
    }
    private func callback(id: UUID, token: String, resource: String, number: Int, state: String) async throws {
        var request = URLRequest(url: origin.appendingPathComponent("v1/webhooks/google"))
        request.httpMethod = "POST"; request.httpBody = Data()
        request.setValue(id.uuidString, forHTTPHeaderField: "X-Goog-Channel-Id")
        request.setValue(token, forHTTPHeaderField: "X-Goog-Channel-Token")
        request.setValue(resource, forHTTPHeaderField: "X-Goog-Resource-Id")
        request.setValue(state, forHTTPHeaderField: "X-Goog-Resource-State")
        request.setValue(String(number), forHTTPHeaderField: "X-Goog-Message-Number")
        let response = try await RelayURLSessionTransport().send(request)
        guard response.head.status == 204 else { throw RelayClientError.rejected(status: response.head.status) }
    }
}

private func awaitLocalRelay(_ condition: @Sendable () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(100))
    }
    throw CalendarError.unavailable("Local relay integration condition timed out.")
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["DAYFOLD_RELAY_INTEGRATION_FILE"] != nil), .timeLimit(.minutes(1)))
func localRelayHTTPStreamsReminderClaimsAndRestartResume() async throws {
    let file = try #require(ProcessInfo.processInfo.environment["DAYFOLD_RELAY_INTEGRATION_FILE"])
    let installation = try JSONDecoder().decode(LocalRelayInstallation.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
    let origin = try RelayEndpoint.validatedOrigin(installation.origin, allowLoopbackHTTP: true)
    guard origin.scheme == "http", ["127.0.0.1", "localhost", "[::1]"].contains(origin.host ?? "") else {
        throw CalendarError.invalid("Integration tests require a loopback service.")
    }
    let client = try RelayClient(baseURL: origin, token: installation.token, allowLoopbackHTTP: true)
    // Refuse a live APNs-capable service even though this test never registers a token.
    #expect(try await client.capabilities().apnsEnabled == false)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dayfold-relay-integration-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("calendar.sqlite").path
    let repository = try CalendarRepository(path: path)
    var account = CalendarAccount(subject: "local-test", email: "relay-test@example.com", scopes: GoogleScope.all)
    account.status = .healthy
    let source = CalendarSource(key: CalendarKey(account: account.id, calendarID: "local-calendar"), title: "Local fixture")
    let reminder = PlannedReminder(id: "dayfold.integration", event: EventKey(calendar: source.key, eventID: "local-event"), title: "Local fixture", source: "Local fixture", fire: Date().addingTimeInterval(8))
    let input = RelayReconciliation(accounts: [account], calendars: [source], desired: [reminder], valid: [reminder], remindersEnabled: true, notificationAuthorization: true)
    let configuration = RelayConfiguration(origin: origin, deviceID: installation.deviceID)
    let watcher = LocalRelayGoogle(origin: origin), sink = LocalRelaySink()
    let callbacks = RelayCallbacks(refresh: { _ in await sink.refreshed() }, applyOwnership: { await sink.own($0) },
        deliverReminder: { _, id in await sink.deliver(id) }, status: { _ in })
    let policy = RelayPolicy(handoffLead: 0, maintenanceInterval: 1, requestTimeout: 10, allowSSEOnlyReminders: true)
    let coordinator = RelayCoordinator(repository: repository, client: client, watcher: watcher, configuration: configuration, callbacks: callbacks, policy: policy)
    var restarted: RelayCoordinator?
    do {
        await coordinator.update(input)
        try await coordinator.start()
        try await awaitLocalRelay { await sink.ready(reminder.id) }
        try await awaitLocalRelay { await sink.deliveries.count == 1 }
        try await awaitLocalRelay {
            let state = try await repository.relayState()
            return state.cursor > 0 && state.cursor == state.acknowledgedCursor && state.delivered.count == 1
        }
        await coordinator.stop()
        let before = try await repository.relayState()
        #expect(before.remoteOwnedIDs.contains(reminder.id))
        #expect(before.watches.contains { $0.activated && !$0.retired })
        let refreshCount = await sink.refreshes
        // Reopen SQLite through a fresh repository and coordinator, like a new process.
        let reopened = try CalendarRepository(path: path)
        let next = RelayCoordinator(repository: reopened, client: client, watcher: watcher, configuration: configuration, callbacks: callbacks, policy: policy)
        restarted = next
        await next.update(RelayReconciliation(accounts: [account], calendars: [source], desired: [], valid: [reminder], remindersEnabled: true, notificationAuthorization: true))
        try await next.start()
        try await watcher.changed()
        try await awaitLocalRelay { await sink.refreshes > refreshCount }
        try await awaitLocalRelay {
            let state = try await reopened.relayState()
            return state.cursor > before.cursor && state.cursor == state.acknowledgedCursor
        }
        #expect(await sink.deliveries.count == 1)
        let remoteID = try #require(before.reminders[reminder.id]?.remoteID)
        #expect(await next.eventForRemote(subjectID: remoteID) == reminder.event)
        try await next.disconnect()
        #expect(try await reopened.relayState().remoteOwnedIDs.isEmpty)
        #expect(await sink.ownership.isEmpty)
    } catch {
        await coordinator.stop(); await restarted?.stop()
        try? await client.revokeDevice()
        throw error
    }
}
