import SwiftUI
import CalendarCore

struct PendingChangesView: View {
    @Bindable var model: AppModel
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                HStack { Text("Local work is retained until you resolve or discard it.").font(.callout).foregroundStyle(.secondary); Spacer(); Button("Export…") { Task { _ = await model.exportRecovery() } } }
                if model.drafts.isEmpty && model.pending.isEmpty { ContentUnavailableView("All caught up", systemImage: "checkmark.circle", description: Text("No drafts or pending changes on this Mac.")) }
                if !model.drafts.isEmpty {
                    Text("Drafts").font(.title3.bold())
                    ForEach(model.drafts) { draft in
                        HStack { VStack(alignment: .leading, spacing: 4) { Text(draft.fields.text("summary", default: "Untitled draft")).fontWeight(.medium); Text(draft.requiresOnlineReview ? "Requires online review before sending" : "Saved on this Mac").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Resume") { if draft.id == "quick-entry-text" { model.quickText = draft.fields.text("quickInput"); model.openQuickEntry?() } else { model.editingDraft = draft } }; Button("Discard", role: .destructive) { Task { try? await model.repository?.discardDraft(draft.id) } } }.padding(16).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                ForEach(model.pending) { mutation in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack { Text(mutation.fields.text("summary", default: mutation.base?.title ?? "Calendar change")).font(.headline); Spacer(); Text(mutation.state.label).font(.caption).foregroundStyle(mutation.state == .conflicted ? .orange : .secondary) }
                        Text(model.sourceLabel(mutation.key.calendar)).font(.caption).foregroundStyle(.secondary)
                        if let previous = mutation.predecessor, model.pending.contains(where: { $0.id == previous }) { Text("Waiting for an earlier change to this event. Resolve that change first.").font(.caption).foregroundStyle(.secondary) }
                        if let conflict = model.conflicts.first(where: { $0.id == mutation.id }) {
                            ForEach(conflict.fields, id: \.self) { field in
                                VStack(alignment: .leading, spacing: 5) { Text(field.capitalized).font(.caption.bold()); Text("Yours: \(display(mutation.fields[field]))"); Text("Google: \(display(conflict.remote?.raw[field]))") }.font(.caption).textSelection(.enabled)
                            }
                            HStack {
                                Button("Keep Google version") { resolve(conflict, local: false) }
                                Button("Apply my change to latest") { resolve(conflict, local: true) }.disabled(conflict.remote == nil)
                                if let base = mutation.base { Button("Save as new personal event…") { var e = base; e.raw.merge(mutation.fields) { _, v in v }; model.duplicate(e) } }
                            }
                        } else {
                            if let category = mutation.errorCategory { Text(explanation(category)).font(.caption).foregroundStyle(.secondary) }
                            HStack {
                                if mutation.state == .blockedAuthorization, let account = model.accounts.first(where: { $0.id == mutation.key.calendar.account }) { Button("Reconnect") { model.connect(expected: account) } }
                                else if mutation.state != .executing && !(mutation.state == .failed && mutation.errorCategory == "invalid") {
                                    Button("Retry") { Task { do { var m = mutation; m.state = m.attempts > 0 ? .uncertain : .queued; m.retryAfter = nil; try await model.repository?.transition(m); await model.dispatcher?.drain(); await model.refresh() } catch { model.errorMessage = error.localizedDescription } } }
                                }
                                if mutation.state == .failed, mutation.errorCategory == "invalid", [.create, .patch].contains(mutation.kind) { Button("Correct details…") { model.correct(mutation) } }
                                if mutation.attempts == 0 && mutation.state == .queued { Button("Undo queued change") { Task { do { try await model.repository?.cancelQueued(mutation.id) } catch { model.errorMessage = error.localizedDescription } } } }
                            }
                        }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                }
                if !model.recentChanges.isEmpty {
                    Text("Recent confirmed changes").font(.title3.bold())
                    ForEach(model.recentChanges) { mutation in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(mutation.confirmedEvent?.title ?? mutation.base?.title ?? "Calendar change").fontWeight(.medium)
                                Text(model.sourceLabel(mutation.key.calendar)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if mutation.kind == .delete, let base = mutation.base {
                                Button("Restore as new personal draft…") { model.duplicate(base) }
                            } else if mutation.confirmedEvent != nil {
                                Button((mutation.reversalDepth ?? 0).isMultiple(of: 2) ? "Undo change…" : "Redo change…") { model.requestReversal(mutation) }
                            }
                        }.padding(12)
                    }
                }
            }.padding(26)
        }
    }
    private func display(_ value: JSONValue?) -> String { guard let value else { return "Unavailable or removed" }; if let string = value.string { return string }; return (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "Unavailable" }
    private func explanation(_ category: String) -> String {
        switch category { case "offline": "Waiting for a connection. The event may already have reached Google; Dayfold checks before retrying."; case "authorization": "Sign in again with the original account."; case "credentials": "Unlock your Mac so Dayfold can read Keychain, then retry. Your credentials have not been removed."; case "permission": "Calendar permissions have changed. Refresh the account and review this change."; case "throttled": "Google asked this account to wait."; case "invalid", "review-required": "This change requires correction. Export it or resume its details as a new personal draft."; default: "The outcome needs to be checked with Google before retrying." }
    }
    private func resolve(_ conflict: EventConflict, local: Bool) { Task { do { try await model.repository?.resolveConflict(conflict.id, applyLocal: local); await model.dispatcher?.drain(); await model.refresh() } catch { model.errorMessage = error.localizedDescription } } }
}
