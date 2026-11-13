import Foundation
import Testing
@testable import CalendarCore

private let relaySyncWindow = DateInterval(start: InternetDate.parse("2026-10-01T00:00:00Z")!, end: InternetDate.parse("2026-12-01T00:00:00Z")!)

private actor RelaySyncProvider: CalendarProvider {
    let base: DemoProvider
    var queries: [(CalendarKey, EventQuery)] = []
    var calendarAccounts: [AccountID] = []
    private var pauseNext = false
    private var paused: CheckedContinuation<Void, Never>?
    private var pauseObservers: [CheckedContinuation<Void, Never>] = []

    init(base: DemoProvider) { self.base = base }
    func pauseNextMetadata() { pauseNext = true }
    func waitUntilPaused() async {
        if paused != nil { return }
        await withCheckedContinuation { pauseObservers.append($0) }
    }
    func isPaused() -> Bool { paused != nil }
    func resumeMetadata() {
        let continuation = paused; paused = nil
        continuation?.resume()
    }
    func calendars(account: AccountID, page: String?) async throws -> ProviderPage<CalendarSource> {
        calendarAccounts.append(account)
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { continuation in
                paused = continuation
                let observers = pauseObservers; pauseObservers = []
                for observer in observers { observer.resume() }
            }
        }
        return try await base.calendars(account: account, page: page)
    }
    func events(source: CalendarSource, query: EventQuery, page: String?) async throws -> ProviderPage<CalendarEvent> {
        queries.append((source.key, query))
        return try await base.events(source: source, query: query, page: page)
    }
    func event(_ key: EventKey, zone: String) async throws -> CalendarEvent { try await base.event(key, zone: zone) }
    func write(_ mutation: Mutation, etag: String?, zone: String) async throws -> CalendarEvent? { try await base.write(mutation, etag: etag, zone: zone) }
    func busy(source: CalendarSource, window: DateInterval) async throws -> [CalendarEvent] { try await base.busy(source: source, window: window) }
}

@Test func relayRefreshDoesNotAcknowledgeACalendarSkippedByTheWorkGate() async throws {
    let fixture = try await Harness.make(events: 8, pageSize: 100)
    let source = try #require(try await fixture.repo.calendar(fixture.data.calendars[0].key))
    let before = try #require(try await fixture.repo.account(source.key.account)).lastSync
    let gate = CalendarWorkGate()
    let coordinator = SyncCoordinator(repository: fixture.repo, provider: fixture.provider, gate: gate)
    #expect(await gate.acquire(source.key))
    await #expect(throws: RelayProcessingError.self) {
        try await coordinator.refreshFromRelay(scopes: [RelayScope(account: source.key.account, calendar: source.key)], window: relaySyncWindow)
    }
    #expect(try await fixture.repo.account(source.key.account)?.lastSync == before)
    await gate.release(source.key)
    try await coordinator.refreshFromRelay(scopes: [RelayScope(account: source.key.account, calendar: source.key)], window: relaySyncWindow)
    #expect(try await fixture.repo.account(source.key.account)?.status == .healthy)
    #expect((try await fixture.repo.account(source.key.account)?.lastSync ?? .distantPast) > (before ?? .distantPast))
}

@Test func relayRefreshWaitsForPollingAndPerformsItsOwnUnthrottledResourcePass() async throws {
    let fixture = try await Harness.make(events: 8, pageSize: 100)
    let source = fixture.data.calendars[0]
    let provider = RelaySyncProvider(base: fixture.provider)
    let coordinator = SyncCoordinator(repository: fixture.repo, provider: provider, gate: CalendarWorkGate())
    await provider.pauseNextMetadata()
    let polling = Task { await coordinator.refresh(window: relaySyncWindow, forceMetadata: true) }
    await provider.waitUntilPaused()
    let required = Task {
        try await coordinator.refreshFromRelay(scopes: [RelayScope(account: source.key.account, calendar: source.key)], window: relaySyncWindow)
    }
    await provider.resumeMetadata()
    await polling.value
    try await required.value
    let resources = await provider.queries.filter { key, query in
        guard key == source.key else { return false }
        if case .resources = query { return true }
        return false
    }
    #expect(resources.count == 2)
}

@Test func cancellingRelayRefreshDoesNotWaitForAnUnrelatedPollingRequest() async throws {
    let fixture = try await Harness.make(events: 8, pageSize: 100)
    let provider = RelaySyncProvider(base: fixture.provider)
    let coordinator = SyncCoordinator(repository: fixture.repo, provider: provider, gate: CalendarWorkGate())
    await provider.pauseNextMetadata()
    let polling = Task { await coordinator.refresh(window: relaySyncWindow, forceMetadata: true) }
    await provider.waitUntilPaused()
    let required = Task {
        do {
            try await coordinator.refreshFromRelay(scopes: nil, window: relaySyncWindow)
            return false
        } catch is CancellationError { return true }
        catch { return false }
    }
    await Task.yield()
    required.cancel()
    // Ensure a regression fails this check rather than hanging the test suite.
    let deadline = Task {
        do { try await Task.sleep(for: .seconds(1)) }
        catch { return }
        await provider.resumeMetadata()
    }
    #expect(await required.value)
    #expect(await provider.isPaused(), "Cancellation must finish before the polling request is released")
    deadline.cancel()
    await provider.resumeMetadata()
    await polling.value
}
