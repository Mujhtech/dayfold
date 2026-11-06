import Foundation
import OSLog

public enum ThreeWayMerge {
    public static let structural: Set<String> = ["start", "end", "recurrence"]
    private static func equal(_ lhs: JSONValue?, _ rhs: JSONValue?) -> Bool { (lhs ?? .null) == (rhs ?? .null) }
    public static func conflicts(base: JSONObject, local: JSONObject, remote: JSONObject) -> [String] {
        var result = Set<String>()
        let changed = Set(local.keys)
        for field in changed where !equal(remote[field], base[field]) && !equal(remote[field], local[field]) { result.insert(field) }
        if !changed.isDisjoint(with: structural) && structural.contains(where: { !equal(remote[$0], base[$0]) }) {
            if !changed.intersection(structural).allSatisfy({ equal(remote[$0], local[$0]) }) { result.formUnion(changed.intersection(structural)) }
        }
        return result.sorted()
    }
    public static func applied(_ fields: JSONObject, to remote: JSONObject) -> Bool { fields.allSatisfy { equal(remote[$0.key], $0.value) } }
}

public actor MutationDispatcher {
    private let logger = Logger(subsystem: "mujhtech.dayfold", category: "mutations")
    private let repository: CalendarRepository
    private let provider: any CalendarProvider
    private let gate: CalendarWorkGate
    private var running = false
    public init(repository: CalendarRepository, provider: any CalendarProvider, gate: CalendarWorkGate) { self.repository = repository; self.provider = provider; self.gate = gate }
    public func drain(now: Date = Date()) async {
        guard !running else { return }; running = true; defer { running = false }
        var attempted: Set<String> = []
        while attempted.count < 100 {
            guard let work = try? await repository.mutations() else { return }
            var queues = Dictionary(grouping: work.filter { !attempted.contains($0.id) && [.queued, .retryScheduled, .uncertain].contains($0.state) && ($0.retryAfter ?? .distantPast) <= now }, by: { $0.key.calendar.account })
            var fair: [Mutation] = []
            let accounts = queues.keys.sorted { $0.rawValue < $1.rawValue }
            while queues.values.contains(where: { !$0.isEmpty }) {
                for account in accounts where queues[account]?.isEmpty == false { fair.append(queues[account]!.removeFirst()) }
            }
            var progressed = false
            for item in fair.prefix(100 - attempted.count) {
                if let dependency = item.predecessor, let previous = try? await repository.mutation(dependency), previous.state.pending { continue }
                guard await gate.acquire(item.key.calendar) else { continue }
                attempted.insert(item.id); progressed = true
                await execute(item, now: now)
                if let outcome = try? await repository.mutation(item.id) { logger.info("write_outcome kind=\(outcome.kind.rawValue, privacy: .public) state=\(outcome.state.rawValue, privacy: .public) attempts=\(outcome.attempts, privacy: .public)") }
                await gate.release(item.key.calendar)
            }
            if !progressed { break }
        }
    }
    private func execute(_ original: Mutation, now: Date) async {
        guard let current = try? await repository.mutation(original.id), [.queued, .retryScheduled, .uncertain].contains(current.state) else { return }
        var m = current
        var accountGeneration: Int?
        do {
            guard let account = try await repository.account(m.key.calendar.account), let source = try await repository.calendar(m.key.calendar), source.syncEnabled else { throw CalendarError.missing }
            accountGeneration = account.generation
            if account.status == .needsReconnection { throw ProviderError.unauthorized }
            let action: EventAction = m.kind == .create ? .create : m.kind == .delete ? .delete : m.kind == .rsvp ? .rsvp : .edit
            let cap = EventCapabilityResolver.resolve(action, account: account, calendar: source, event: m.base)
            guard cap.allowed else { throw CalendarError.permission(cap.reason) }
            var etag: String?
            if m.kind == .create {
                if m.attempts > 0 || m.state == .uncertain {
                    do {
                        let existing = try await provider.event(m.key, zone: source.timeZone)
                        guard existing.raw["extendedProperties"]?["private"]["dayfoldOperation"].string == m.id else { throw CalendarError.invalid("An unrelated event uses this identifier. Export this change for recovery.") }
                        try await repository.confirm(m, event: existing); return
                    } catch ProviderError.missing { /* Reuse the exact persisted event ID below. */ }
                }
            } else {
                let current: CalendarEvent
                do { current = try await provider.event(m.key, zone: source.timeZone) }
                catch ProviderError.missing {
                    // A 404 may be permission loss. Re-read all calendar metadata before concluding deletion.
                    let role = try await verifiedSource(m.key.calendar)
                    guard role.readable else { throw ProviderError.forbidden }
                    if m.kind == .delete { try await repository.confirm(m, event: nil); return }
                    try await repository.recordConflict(EventConflict(mutation: m, remote: nil, fields: ["event deleted"])); return
                }
                let currentCap = EventCapabilityResolver.resolve(action, account: account, calendar: source, event: current)
                guard currentCap.allowed else { throw CalendarError.permission(currentCap.reason) }
                if m.kind == .rsvp {
                    guard let requested = m.fields["attendees"]?.array?.first?["responseStatus"].string,
                          let selfAttendee = current.selfAttendee,
                          m.fields["attendees"]?.array?.first?["email"].string == selfAttendee.text("email") else { throw CalendarError.permission("The invited identity changed. Review the invitation in Google Calendar.") }
                    if current.response == requested { try await repository.confirm(m, event: current); return }
                } else if m.kind != .delete && ThreeWayMerge.applied(m.fields, to: current.raw) { try await repository.confirm(m, event: current); return }
                let conflicts = m.kind == .rsvp ? (current.response != m.base?.response ? ["your response"] : []) : ThreeWayMerge.conflicts(base: m.base?.raw ?? [:], local: m.fields, remote: current.raw)
                if !conflicts.isEmpty || (m.kind == .delete && m.base?.etag != current.etag) {
                    try await repository.recordConflict(EventConflict(mutation: m, remote: current, fields: conflicts.isEmpty ? ["event"] : conflicts)); return
                }
                guard let currentETag = current.etag else { throw ProviderError.malformed }; etag = currentETag
                if m.fields["attendees"] != nil && m.kind != .rsvp && current.raw.flag("attendeesOmitted") { throw CalendarError.invalid("Google returned an incomplete guest list. Manage guests in Google Calendar.") }
            }
            guard try await repository.account(account.id)?.generation == account.generation else { throw CalendarError.staleGeneration }
            guard let claimed = try await repository.beginExecution(m, accountGeneration: account.generation, sourceGeneration: source.generation) else { return }
            m = claimed
            let result = try await provider.write(m, etag: etag, zone: source.timeZone)
            guard try await repository.account(account.id)?.generation == account.generation else { return }
            try await repository.confirm(m, event: result)
        } catch {
            if let accountGeneration, (try? await repository.account(m.key.calendar.account)?.generation) != accountGeneration { return }
            if error is CancellationError { m.state = .uncertain; m.errorCategory = "interrupted" }
            else if let p = error as? ProviderError {
                m.errorCategory = p.category
                switch p {
                case .duplicate, .network, .server, .malformed: m.state = m.attempts > 0 ? .uncertain : .retryScheduled
                case .unauthorized: m.state = .blockedAuthorization; try? await repository.setAccountStatus(m.key.calendar.account, .needsReconnection)
                case .credentialsUnavailable: m.state = .retryScheduled; m.retryAfter = now.addingTimeInterval(60); try? await repository.setAccountStatus(m.key.calendar.account, .keychainUnavailable)
                case .conflict: m.state = .uncertain
                case .throttled(let seconds): m.state = .retryScheduled; m.retryAfter = now.addingTimeInterval(seconds ?? 60)
                case .forbidden: m.state = .failed; try? await repository.setAccountStatus(m.key.calendar.account, .discovering)
                case .organization: m.state = .failed; try? await repository.setAccountStatus(m.key.calendar.account, .blockedByOrganization)
                default: m.state = .failed
                }
            } else { m.state = .failed; m.errorCategory = "review-required" }
            if [.uncertain, .retryScheduled].contains(m.state), m.retryAfter == nil {
                m.retryAfter = now.addingTimeInterval(min(3600, pow(2, Double(min(m.attempts + 1, 10)))) + Double.random(in: 0...2))
            }
            try? await repository.transition(m)
        }
    }
    private func verifiedSource(_ key: CalendarKey) async throws -> CalendarSource {
        var page: String?, seen = Set<String>()
        repeat {
            let result = try await provider.calendars(account: key.account, page: page)
            if let match = result.items.first(where: { $0.key == key && !$0.deleted }) { return match }
            page = result.nextPage
            if let page, !seen.insert(page).inserted { throw ProviderError.malformed }
        } while page != nil
        throw ProviderError.forbidden
    }
}
