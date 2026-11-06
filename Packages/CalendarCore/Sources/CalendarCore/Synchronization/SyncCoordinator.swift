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
    private var metadataTimes: [AccountID: Date] = [:]
    private var resourceTimes: [CalendarKey: Date] = [:]
    public init(repository: CalendarRepository, provider: any CalendarProvider, gate: CalendarWorkGate) { self.repository = repository; self.provider = provider; self.gate = gate }

    public func refresh(window: DateInterval, forceMetadata: Bool = false) async {
        requestedWindow = window
        guard !running else { return }
        let started = Date()
        running = true
        defer { running = false; logger.info("refresh_complete duration_ms=\(Int(Date().timeIntervalSince(started) * 1000), privacy: .public)") }
        while let next = requestedWindow {
            requestedWindow = nil
            guard let accounts = try? await repository.accounts() else { return }
            // Two independent accounts can progress; a failed account does not stop the next.
            await withTaskGroup(of: Void.self) { group in
                var iterator = accounts.makeIterator()
                for _ in 0..<2 { if let a = iterator.next() { group.addTask { await self.refreshAccount(a, window: next, forceMetadata: forceMetadata) } } }
                while await group.next() != nil { if let a = iterator.next() { group.addTask { await self.refreshAccount(a, window: next, forceMetadata: forceMetadata) } } }
            }
        }
    }
    private func refreshAccount(_ account: CalendarAccount, window: DateInterval, forceMetadata: Bool) async {
        guard account.status != .removing, account.status != .needsReconnection, account.status != .blockedByOrganization || forceMetadata,
              (account.retryAfter ?? .distantPast) <= Date() else { return }
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
            for source in sources {
                do { try await refreshCalendar(source, window: window) } catch {
                    firstError = firstError ?? error
                    if let p = error as? ProviderError, ["authorization", "credentials", "organization", "throttled"].contains(p.category) { break }
                }
            }
            if let firstError { throw firstError }
            try await repository.setAccountStatus(account.id, .healthy, success: Date(), generation: account.generation)
        } catch {
            let p = error as? ProviderError
            let status: AccountStatus = p == .unauthorized ? .needsReconnection : p == .credentialsUnavailable ? .keychainUnavailable : p == .organization ? .blockedByOrganization : p?.category == "throttled" ? .throttled : .offline
            var minimumDelay: TimeInterval = p == .credentialsUnavailable ? 60 : 0
            if case .throttled(let seconds) = p { minimumDelay = seconds ?? 60 }
            try? await repository.recordSyncFailure(account, status: status, now: Date(), minimumDelay: minimumDelay, jitter: Double.random(in: 0...2))
            if p == .forbidden || p == .missing { metadataTimes[account.id] = nil }
        }
    }
    public func refreshCalendar(_ source: CalendarSource, window: DateInterval) async throws {
        guard await gate.acquire(source.key) else { return }
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
