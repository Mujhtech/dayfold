import AppKit
import CalendarCore

extension AppModel {
    var undoCandidate: Mutation? {
        pending.last(where: { $0.state == .queued && $0.attempts == 0 }) ?? recentChanges.first(where: { ($0.reversalDepth ?? 0).isMultiple(of: 2) })
    }
    var redoCandidate: Mutation? {
        queuedRedo ?? recentChanges.first(where: { !($0.reversalDepth ?? 0).isMultiple(of: 2) })
    }
    func undoCalendarChange() {
        guard let mutation = undoCandidate else { return }
        if mutation.state == .queued {
            Task { do { try await repository?.cancelQueued(mutation.id); queuedRedo = mutation } catch { errorMessage = error.localizedDescription } }
        } else { requestReversal(mutation) }
    }
    func redoCalendarChange() {
        if var mutation = queuedRedo {
            mutation.state = .queued
            Task { do { try await repository?.enqueue(mutation); queuedRedo = nil; await dispatcher?.drain(); await refresh() } catch { errorMessage = error.localizedDescription } }
        } else if let mutation = redoCandidate { requestReversal(mutation) }
    }
    func requestReversal(_ mutation: Mutation) {
        if mutation.kind == .delete, let event = mutation.base { duplicate(event) }
        else { reversalRequest = mutation; openCalendar?() }
    }
    func confirmReversal() {
        guard let mutation = reversalRequest else { return }; reversalRequest = nil
        Task { do { try await repository?.reverseConfirmed(mutation.id); await dispatcher?.drain(); await refresh() } catch { errorMessage = error.localizedDescription } }
    }
}
