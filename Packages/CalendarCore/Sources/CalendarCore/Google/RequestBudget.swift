import Foundation

/// Shared by all Google operations in an app session. Limits both bursts and in-flight work.
public actor RequestBudget {
    public struct Policy: Sendable {
        public var globalConcurrent: Int
        public var accountConcurrent: Int
        public var globalRequests: Int
        public var accountRequests: Int
        public var interval: TimeInterval
        public init(globalConcurrent: Int = 4, accountConcurrent: Int = 2, globalRequests: Int = 120, accountRequests: Int = 60, interval: TimeInterval = 60) {
            self.globalConcurrent = max(1, globalConcurrent); self.accountConcurrent = max(1, accountConcurrent)
            self.globalRequests = max(1, globalRequests); self.accountRequests = max(1, accountRequests); self.interval = max(0.01, interval)
        }
    }
    private struct Waiting {
        var id: UUID
        var account: AccountID
        var continuation: CheckedContinuation<Void, any Error>
    }
    private let policy: Policy
    private var active: [AccountID: Int] = [:]
    private var starts: [(AccountID, Date)] = []
    private var pauses: [AccountID: Date] = [:]
    private var waiting: [Waiting] = []
    private var timer: Task<Void, Never>?
    public init(policy: Policy = Policy()) { self.policy = policy }

    public func acquire(_ account: AccountID) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiting.append(Waiting(id: id, account: account, continuation: continuation)); pump()
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    public func release(_ account: AccountID) {
        active[account] = max(0, active[account, default: 0] - 1); pump()
    }
    public func pause(_ account: AccountID, seconds: TimeInterval) {
        pauses[account] = max(pauses[account, default: .distantPast], Date().addingTimeInterval(min(86_400, max(0, seconds))))
        pump()
    }
    private func cancel(_ id: UUID) {
        if let index = waiting.firstIndex(where: { $0.id == id }) { waiting.remove(at: index).continuation.resume(throwing: CancellationError()) }
        pump()
    }
    private func pump() {
        timer?.cancel(); timer = nil
        let now = Date()
        starts.removeAll { now.timeIntervalSince($0.1) >= policy.interval }
        var nextWake: Date?
        var index = 0
        while index < waiting.count {
            let item = waiting[index]
            if active.values.reduce(0, +) >= policy.globalConcurrent { break }
            if active[item.account, default: 0] >= policy.accountConcurrent { index += 1; continue }
            let accountStarts = starts.filter { $0.0 == item.account }
            var eligible = pauses[item.account, default: .distantPast]
            if starts.count >= policy.globalRequests { eligible = max(eligible, starts[starts.count - policy.globalRequests].1.addingTimeInterval(policy.interval)) }
            if accountStarts.count >= policy.accountRequests { eligible = max(eligible, accountStarts[accountStarts.count - policy.accountRequests].1.addingTimeInterval(policy.interval)) }
            if eligible > now { nextWake = min(nextWake ?? eligible, eligible); index += 1; continue }
            active[item.account, default: 0] += 1; starts.append((item.account, now))
            waiting.remove(at: index).continuation.resume()
        }
        if let wake = nextWake, !waiting.isEmpty {
            let delay = max(0.01, wake.timeIntervalSince(now))
            timer = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                await self?.pump()
            }
        }
    }
}
