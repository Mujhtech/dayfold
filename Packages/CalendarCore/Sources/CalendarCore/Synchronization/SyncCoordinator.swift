import Foundation
import OSLog

/// Explicit leases survive actor reentrancy and coordinate reads with writes per calendar.
public actor CalendarWorkGate {
    private var held: Set<CalendarKey> = []
    public init() {}
    public func acquire(_ key: CalendarKey) -> Bool { held.insert(key).inserted }
    public func release(_ key: CalendarKey) { held.remove(key) }
}

public actor SyncCoordinator {
    private let logger = Logger(subsystem: "mujhtech.dayfold", category: "sync")
    let repository: CalendarRepository
    let provider: any CalendarProvider
    let gate: CalendarWorkGate
    private var running = false
    private var requestedWindow: DateInterval?
    private var requestedMetadataRefresh = false
    private var metadataTimes: [AccountID: Date] = [:]
    private var resourceTimes: [CalendarKey: Date] = [:]
    private var idleWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    public init(repository: CalendarRepository, provider: any CalendarProvider, gate: CalendarWorkGate) { self.repository = repository; self.provider = provider; self.gate = gate }

    public func refresh(window: DateInterval, forceMetadata: Bool = false) async {
        requestedWindow = window
        requestedMetadataRefresh = requestedMetadataRefresh || forceMetadata
        guard !running else { return }
        let started = Date()
        running = true
        defer {
            finishRefresh()
            logger.info("refresh_complete duration_ms=\(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)")
        }
        await drainRefreshQueue()
    }

    private func drainRefreshQueue() async {
        while let next = requestedWindow {
            guard !Task.isCancelled else { return }
            requestedWindow = nil
            let forceMetadata = requestedMetadataRefresh
            requestedMetadataRefresh = false
            guard let accounts = try? await repository.accounts() else { return }
            _ = await refreshAccounts(accounts, window: next, forceMetadata: forceMetadata)
        }
    }
    /// A push invalidates freshness throttles but still uses the existing gated,
    /// incremental Google sync path. Waiting here prevents acknowledging work
    /// merely because a polling refresh was already running.
    public func refreshFromRelay(scopes: Set<RelayScope>?, window: DateInterval) async throws {
        try await waitUntilIdle()
        // Reserve the refresh before the first repository await. Otherwise a
        // polling refresh can enter here and make refresh() return immediately.
        running = true
        defer { finishRefresh() }
        let started = Date()
        let accounts = try await repository.accounts()
        let accountIDs = scopes.map { Set($0.map(\.account)) }
        let selected = accounts.filter { accountIDs == nil || accountIDs!.contains($0.id) }
        for account in selected {
            metadataTimes[account.id] = nil
            for key in Array(resourceTimes.keys) where key.account == account.id { resourceTimes[key] = nil }
        }
        let completed = await refreshAccounts(selected, window: window, forceMetadata: true)
        try Task.checkCancellation()
        // Honor regular refresh requests queued while this required pass ran.
        // Their result cannot turn a skipped required calendar into success.
        await drainRefreshQueue()
        try Task.checkCancellation()
        let generations = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0.generation) })
        let refreshed = try await repository.accounts().filter { accountIDs == nil || accountIDs!.contains($0.id) }
        guard completed,
              refreshed.filter({ $0.status != .removing }).allSatisfy({ $0.generation == generations[$0.id] && $0.status == .healthy && ($0.lastSync ?? .distantPast) >= started }) else {
            throw RelayProcessingError.syncIncomplete
        }
    }

    private func waitUntilIdle() async throws {
        try Task.checkCancellation()
        while running {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { idleWaiters[id] = continuation }
                }
            } onCancel: {
                Task { await self.cancelIdleWaiter(id) }
            }
        }
        try Task.checkCancellation()
    }

    private func cancelIdleWaiter(_ id: UUID) {
        idleWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func finishRefresh() {
        running = false
        let waiters = Array(idleWaiters.values)
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func refreshAccounts(_ accounts: [CalendarAccount], window: DateInterval, forceMetadata: Bool) async -> Bool {
        // Two independent accounts can progress; a failed account does not stop the next.
        await withTaskGroup(of: Bool.self) { group in
            var iterator = accounts.makeIterator()
            for _ in 0..<2 {
                if let account = iterator.next() { group.addTask { await self.refreshAccount(account, window: window, forceMetadata: forceMetadata) } }
            }
            var completed = true
            while let result = await group.next() {
                completed = result && completed
                if let account = iterator.next() { group.addTask { await self.refreshAccount(account, window: window, forceMetadata: forceMetadata) } }
            }
            return completed
        }
    }

    private func refreshAccount(_ account: CalendarAccount, window: DateInterval, forceMetadata: Bool) async -> Bool {
        if account.status == .removing { return true }
        guard account.status != .removing, account.status != .needsReconnection, account.status != .blockedByOrganization || forceMetadata,
              (account.retryAfter ?? .distantPast) <= Date() else { return false }
        do {
            if forceMetadata || account.status == .discovering || Date().timeIntervalSince(metadataTimes[account.id, default: .distantPast]) > 900 {
                var all: [CalendarSource] = [], page: String?, seen = Set<String>()
                repeat {
                    try Task.checkCancellation()
                    let result = try await provider.calendars(account: account.id, page: page)
                    all.append(contentsOf: result.items); page = result.nextPage
                    if let page, !seen.insert(page).inserted { throw ProviderError.malformed }
                } while page != nil
                try await repository.reconcileCalendars(all, account: account.id, generation: account.generation)
                metadataTimes[account.id] = Date()
            }
            let sources = try await repository.calendars().filter { $0.key.account == account.id && $0.syncEnabled && !$0.deleted }
            var firstError: (any Error)?
            var completed = true
            for source in sources {
                do { completed = try await refreshCalendar(source, window: window) && completed } catch {
                    firstError = firstError ?? error
                    if let p = error as? ProviderError, ["authorization", "credentials", "organization", "throttled"].contains(p.category) { break }
                }
            }
            if let firstError { throw firstError }
            // A busy calendar is deferred work, not a successful sync and not a
            // connectivity failure. The next relay replay or poll can retry it.
            guard completed else { return false }
            try Task.checkCancellation()
            try await repository.setAccountStatus(account.id, .healthy, success: Date(), generation: account.generation)
            return true
        } catch {
            if error is CancellationError { return false }
            let p = error as? ProviderError
            let status: AccountStatus = p == .unauthorized ? .needsReconnection : p == .credentialsUnavailable ? .keychainUnavailable : p == .organization ? .blockedByOrganization : p?.category == "throttled" ? .throttled : .offline
            var minimumDelay: TimeInterval = p == .credentialsUnavailable ? 60 : 0
            if case .throttled(let seconds) = p { minimumDelay = seconds ?? 60 }
            try? await repository.recordSyncFailure(account, status: status, now: Date(), minimumDelay: minimumDelay, jitter: Double.random(in: 0...2))
            if p == .forbidden || p == .missing { metadataTimes[account.id] = nil }
            return false
        }
    }
    @discardableResult public func refreshCalendar(_ source: CalendarSource, window: DateInterval) async throws -> Bool {
        guard await gate.acquire(source.key) else { return false }
        do {
            if source.freeBusyOnly {
                let run = UUID().uuidString
                let busy = try await provider.busy(source: source, window: window)
                try await repository.stage(busy, run: run, source: source)
                try await repository.publish(run: run, source: source, window: window)
            } else if source.readable {
                let cursor = try await repository.cursor(source.key, fingerprint: EventQuery.fingerprint)
                if cursor == nil { try await fetch(source, query: .occurrences(window), window: window) }
                if cursor == nil || Date().timeIntervalSince(resourceTimes[source.key, default: .distantPast]) > 45 {
                    do { try await fetch(source, query: .resources(syncToken: cursor), replace: cursor == nil) }
                    catch ProviderError.expiredCursor {
                        try await repository.clearCursor(source.key)
                        try await fetch(source, query: .resources(syncToken: nil), replace: true)
                    }
                    resourceTimes[source.key] = Date()
                }
                try await fetch(source, query: .occurrences(window), window: window)
            }
            try await repository.recordCalendarSync(source, success: Date())
            await gate.release(source.key)
            return true
        } catch {
            try? await repository.markCoverageStale(source)
            try? await repository.recordCalendarSync(source, error: (error as? ProviderError)?.category ?? "unavailable")
            await gate.release(source.key); throw error
        }
    }
    public func prefetch(window: DateInterval) async {
        guard !running, let sources = try? await repository.calendars() else { return }
        for source in sources where source.syncEnabled && source.readable && !source.deleted {
            guard !Task.isCancelled, !running else { return }
            guard let account = try? await repository.account(source.key.account), account.status == .healthy, (account.retryAfter ?? .distantPast) <= Date() else { continue }
            let coverage = try? await repository.coverage(for: source.key)
            if coverage?.contains(where: { !$0.stale && $0.interval.start <= window.start && $0.interval.end >= window.end }) == true { continue }
            guard await gate.acquire(source.key) else { continue }
            do { try await fetch(source, query: .occurrences(window), window: window) } catch { /* The previous complete window remains available. */ }
            await gate.release(source.key)
        }
    }
    private func fetch(_ source: CalendarSource, query: EventQuery, replace: Bool = false, window: DateInterval? = nil) async throws {
        let run = UUID().uuidString
        do {
            var page: String?, token: String?, seen = Set<String>()
            repeat {
                try Task.checkCancellation()
                let response = try await provider.events(source: source, query: query, page: page)
                try await repository.stage(response.items, run: run, source: source)
                page = response.nextPage; token = response.syncToken
                if let page, !seen.insert(page).inserted { throw ProviderError.malformed }
            } while page != nil
            try await repository.publish(run: run, source: source, token: token, fingerprint: EventQuery.fingerprint, replaceResources: replace, window: window)
        } catch { try? await repository.abandonStage(run); throw error }
    }
}
