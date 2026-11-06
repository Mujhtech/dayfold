import Foundation

/// One token operation per account, with cancellation generations across reconnects.
public actor TokenRequestPool {
    private struct Entry {
        var id: UUID
        var forceRefresh: Bool
        var task: Task<String, Error>
    }
    private var entries: [AccountID: Entry] = [:]
    private var generations: [AccountID: Int] = [:]
    public init() {}

    public func value(for account: AccountID, forceRefresh: Bool, operation: @escaping @Sendable (Bool) async throws -> String) async throws -> String {
        let generation = generations[account, default: 0]
        if let entry = entries[account] {
            let value = try await entry.task.value
            guard generations[account, default: 0] == generation else { throw CancellationError() }
            // A 401 must not be satisfied by a concurrent cached-token lookup.
            if forceRefresh && !entry.forceRefresh {
                if entries[account]?.id == entry.id { entries[account] = nil }
                return try await self.value(for: account, forceRefresh: true, operation: operation)
            }
            return value
        }
        let id = UUID(), task = Task { try await operation(forceRefresh) }
        entries[account] = Entry(id: id, forceRefresh: forceRefresh, task: task)
        defer { if entries[account]?.id == id { entries[account] = nil } }
        let value = try await task.value
        guard generations[account, default: 0] == generation else { throw CancellationError() }
        return value
    }
    public func invalidate(_ account: AccountID) {
        generations[account, default: 0] += 1
        entries[account]?.task.cancel(); entries[account] = nil
    }
}
