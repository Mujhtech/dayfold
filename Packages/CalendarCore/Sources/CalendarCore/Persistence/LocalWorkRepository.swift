import Foundation
import GRDB

extension CalendarRepository {
    public func correctionDraft(for id: String) throws -> EventDraft {
        let draft = try database.read { db in
            guard let m = try Self.decode(Mutation.self, row: Row.fetchOne(db, sql: "SELECT payload FROM mutations WHERE id=?", arguments: [id])),
                  m.state == .failed, m.errorCategory == "invalid", [.create, .patch].contains(m.kind) else {
                throw CalendarError.invalid("Only a change rejected by Google can be corrected here. Retry uncertain changes to check their outcome first.")
            }
            var fields = m.base?.raw ?? [:]; fields.merge(m.fields) { _, value in value }
            var result = EventDraft(calendar: m.key.calendar, source: m.base, fields: fields)
            result.repairingMutationID = id
            return result
        }
        try saveDraft(draft); return draft
    }
    /// A definitive rejection can be revised without changing provider identity or dependencies.
    public func reviseRejected(_ id: String, fields: JSONObject, draftID: String) throws {
        try database.write { db in
            guard var m = try Self.decode(Mutation.self, row: Row.fetchOne(db, sql: "SELECT payload FROM mutations WHERE id=?", arguments: [id])),
                  m.state == .failed, m.errorCategory == "invalid", [.create, .patch].contains(m.kind),
                  var source = try Self.calendar(m.key.calendar, db) else { throw CalendarError.invalid("This change's state has changed. Review Pending Changes before correcting it.") }
            let capability = EventCapabilityResolver.resolve(m.kind == .create ? .create : .edit, account: try Self.account(m.key.calendar.account, db), calendar: source, event: m.base)
            guard capability.allowed else { throw CalendarError.permission(capability.reason) }
            m.fields = fields
            if m.kind == .create { m.fields["extendedProperties"] = .object(["private": .object(["dayfoldOperation": .string(m.id)])]) }
            m.state = .queued; m.retryAfter = nil; m.errorCategory = nil
            try Self.putMutation(m, db); try Self.closeDraft(draftID, db: db)
            source.writeEpoch += 1; try Self.putCalendar(source, db); try Self.staleWindows(source.key, db)
        }; changed()
    }
    /// Draft deletion, mutation intent, and projection source commit atomically.
    @discardableResult public func enqueue(_ proposed: Mutation, draftID: String? = nil) throws -> Mutation {
        let result = try database.write { db in
            let calendar = try Self.calendar(proposed.key.calendar, db), account = try Self.account(proposed.key.calendar.account, db)
            let action: EventAction = proposed.kind == .create ? .create : proposed.kind == .delete ? .delete : proposed.kind == .rsvp ? .rsvp : .edit
            let cap = EventCapabilityResolver.resolve(action, account: account, calendar: calendar, event: proposed.base)
            guard cap.allowed else { throw CalendarError.permission(cap.reason) }
            var m = proposed
            let pending = try Self.readAll(Mutation.self, table: "mutations", db: db).filter { $0.key == m.key && $0.state.pending }.sorted { $0.created < $1.created }
            if let same = pending.first(where: { $0.id == m.id }) { return same }
            if var last = pending.last, last.state == .queued && last.attempts == 0 {
                if last.kind == .create && m.kind == .delete {
                    last.state = .cancelled; try Self.putMutation(last, db); m = last
                } else if (last.kind == .create || last.kind == .patch) && m.kind == .patch && last.sendUpdates == m.sendUpdates {
                    last.fields.merge(m.fields) { _, new in new }; try Self.putMutation(last, db); m = last
                } else if last.kind == .rsvp && m.kind == .rsvp && last.sendUpdates == m.sendUpdates {
                    last.fields = m.fields; try Self.putMutation(last, db); m = last
                } else {
                    m.predecessor = last.id; try Self.putMutation(m, db)
                }
            } else {
                m.predecessor = pending.last?.id; try Self.putMutation(m, db)
            }
            if var calendar { calendar.writeEpoch += 1; try Self.putCalendar(calendar, db); try Self.staleWindows(calendar.key, db) }
            if let draftID { try Self.closeDraft(draftID, db: db) }
            return m
        }; changed(); return result
    }
    public func transition(_ mutation: Mutation) throws {
        try database.write { db in
            guard try Self.account(mutation.key.calendar.account, db) != nil else { throw CalendarError.missing }
            if let current = try Self.decode(Mutation.self, row: Row.fetchOne(db, sql: "SELECT payload FROM mutations WHERE id=?", arguments: [mutation.id])),
               !current.state.pending || current.fields != mutation.fields || current.base != mutation.base { return }
            try Self.putMutation(mutation, db)
        }; changed()
    }
    /// An undo or coalesced edit can race a network preflight. Claim only the version
    /// that was reviewed, atomically, immediately before transmitting its write.
    public func beginExecution(_ reviewed: Mutation, accountGeneration: Int? = nil, sourceGeneration: Int? = nil) throws -> Mutation? {
        let result = try database.write { db -> Mutation? in
            guard var current = try Self.decode(Mutation.self, row: Row.fetchOne(db, sql: "SELECT payload FROM mutations WHERE id=?", arguments: [reviewed.id])),
                  [.queued, .retryScheduled, .uncertain].contains(current.state),
                  current.fields == reviewed.fields, current.base == reviewed.base else { return nil }
            guard let source = try Self.calendar(current.key.calendar, db), let account = try Self.account(current.key.calendar.account, db), source.syncEnabled,
                  accountGeneration == nil || account.generation == accountGeneration,
                  sourceGeneration == nil || source.generation == sourceGeneration else { throw CalendarError.staleGeneration }
            let action: EventAction = current.kind == .create ? .create : current.kind == .delete ? .delete : current.kind == .rsvp ? .rsvp : .edit
            let capability = EventCapabilityResolver.resolve(action, account: account, calendar: source, event: current.base)
            guard capability.allowed else { throw CalendarError.permission(capability.reason) }
            current.state = .executing; current.attempts += 1; current.retryAfter = nil
            try Self.putMutation(current, db); return current
        }
        if result != nil { changed() }; return result
    }
    public func confirm(_ mutation: Mutation, event: CalendarEvent?) throws {
        try database.write { db in
            guard var calendar = try Self.calendar(mutation.key.calendar, db), !calendar.deleted else { throw CalendarError.missing }
            guard let current = try Self.decode(Mutation.self, row: Row.fetchOne(db, sql: "SELECT payload FROM mutations WHERE id=?", arguments: [mutation.id])), current.state.pending,
                  current.fields == mutation.fields, current.base == mutation.base else { return }
            if let event {
                guard event.key == mutation.key else { throw CalendarError.invalid("The write response has a different identity.") }
                try Self.putEvent(event, kind: "resource", db)
                if event.recurrence.isEmpty { try Self.putEvent(event, kind: "occurrence", db) }
            } else {
                try db.execute(sql: "DELETE FROM events WHERE id=?", arguments: [mutation.key.id])
                try db.execute(sql: "DELETE FROM search_documents WHERE id=?", arguments: [mutation.key.id])
            }
            var m = mutation; m.state = .confirmed; m.errorCategory = nil; m.confirmedEvent = event; try Self.putMutation(m, db)
            for var next in try Self.readAll(Mutation.self, table: "mutations", db: db) where next.predecessor == m.id && next.state.pending {
                next.base = event; next.predecessor = nil; try Self.putMutation(next, db)
            }
            calendar.writeEpoch += 1; try Self.putCalendar(calendar, db); try Self.staleWindows(calendar.key, db)
            try db.execute(sql: "DELETE FROM conflicts WHERE id=?", arguments: [m.id])
        }; changed()
    }
    public func recordConflict(_ conflict: EventConflict) throws {
        try database.write { db in
            guard let current = try Self.decode(Mutation.self, row: Row.fetchOne(db, sql: "SELECT payload FROM mutations WHERE id=?", arguments: [conflict.id])), current.state.pending,
                  current.fields == conflict.mutation.fields, current.base == conflict.mutation.base else { return }
            var m = conflict.mutation; m.state = .conflicted; try Self.putMutation(m, db)
            try Self.put(conflict, id: conflict.id, table: "conflicts", db: db)
        }; changed()
    }
    public func cancelQueued(_ id: String) throws {
        try database.write { db in
            guard var m = try Self.decode(Mutation.self, row: Row.fetchOne(db, sql: "SELECT payload FROM mutations WHERE id=?", arguments: [id])) else { return }
            guard m.attempts == 0 && m.state == .queued else { throw CalendarError.invalid("This change may already have reached Google. Review it before reversing it.") }
            let dependents = try Self.readAll(Mutation.self, table: "mutations", db: db).filter { $0.predecessor == m.id && $0.state.pending }
            guard dependents.isEmpty else { throw CalendarError.invalid("Undo the later change for this event first.") }
            m.state = .cancelled; try Self.putMutation(m, db)
            if let reversed = m.reverses, var original = try Self.decode(Mutation.self, row: Row.fetchOne(db, sql: "SELECT payload FROM mutations WHERE id=?", arguments: [reversed])) {
                original.reversedBy = nil; try Self.putMutation(original, db)
            }
        }; changed()
    }
    @discardableResult public func reverseConfirmed(_ id: String) throws -> Mutation {
        let result = try database.write { db in
            guard var original = try Self.decode(Mutation.self, row: Row.fetchOne(db, sql: "SELECT payload FROM mutations WHERE id=?", arguments: [id])), original.reversedBy == nil else { throw CalendarError.missing }
            let reversal = try MutationReversal.make(original)
            guard try !Self.readAll(Mutation.self, table: "mutations", db: db).contains(where: { $0.key == original.key && $0.state.pending }) else { throw CalendarError.invalid("Resolve the pending change for this event before undoing an earlier one.") }
            guard var source = try Self.calendar(original.key.calendar, db) else { throw CalendarError.missing }
            let action: EventAction = reversal.kind == .delete ? .delete : reversal.kind == .rsvp ? .rsvp : .edit
            let capability = EventCapabilityResolver.resolve(action, account: try Self.account(source.key.account, db), calendar: source, event: reversal.base)
            guard capability.allowed else { throw CalendarError.permission(capability.reason) }
            original.reversedBy = reversal.id
            try Self.putMutation(original, db); try Self.putMutation(reversal, db)
            source.writeEpoch += 1; try Self.putCalendar(source, db); try Self.staleWindows(source.key, db)
            return reversal
        }; changed(); return result
    }
    public func resolveConflict(_ id: String, applyLocal: Bool) throws {
        try database.write { db in
            guard let conflict = try Self.decode(EventConflict.self, row: Row.fetchOne(db, sql: "SELECT payload FROM conflicts WHERE id=?", arguments: [id])) else { throw CalendarError.missing }
            var m = conflict.mutation
            if let source = try Self.calendar(m.key.calendar, db), source.readable, !source.deleted, let remote = conflict.remote, !remote.redacted {
                try Self.putEvent(remote, kind: "resource", db)
                if remote.recurrence.isEmpty { try Self.putEvent(remote, kind: "occurrence", db) }
            }
            if applyLocal {
                guard let remote = conflict.remote else { throw CalendarError.invalid("The original event is gone. Save a new personal event instead.") }
                m.base = remote; m.state = .queued; m.retryAfter = nil; m.errorCategory = nil
            } else {
                m.state = .cancelled
                for var next in try Self.readAll(Mutation.self, table: "mutations", db: db) where next.predecessor == m.id && next.state.pending {
                    next.base = conflict.remote; next.predecessor = nil; try Self.putMutation(next, db)
                }
            }
            try Self.putMutation(m, db); try db.execute(sql: "DELETE FROM conflicts WHERE id=?", arguments: [id])
        }; changed()
    }
    public func rebuildRemoteCache() throws {
        try database.write { db in
            // Unsent intent, drafts and conflicts are independent tables and survive this operation.
            try db.execute(sql: "DELETE FROM cursors; DELETE FROM staging;")
            for var c in try Self.readAll(CalendarSource.self, table: "calendars", db: db) {
                c.generation += 1; try Self.putCalendar(c, db); try Self.staleWindows(c.key, db)
            }
        }; changed()
    }
    public func recoveryExport(account: AccountID? = nil) throws -> Data {
        struct SourceLabel: Encodable { var key: CalendarKey; var accountLabel: String; var calendarTitle: String; var timeZone: String }
        struct Recovery: Encodable { var format = "dayfold-recovery"; var version = 1; var created: Date; var sources: [SourceLabel]; var drafts: [EventDraft]; var pendingChanges: [Mutation]; var conflicts: [EventConflict] }
        return try database.read { db in
            let accounts = try Self.readAll(CalendarAccount.self, table: "accounts", db: db)
            let sources = try Self.readAll(CalendarSource.self, table: "calendars", db: db).filter { account == nil || $0.key.account == account }.map { source in
                SourceLabel(key: source.key, accountLabel: accounts.first { $0.id == source.key.account }?.label ?? "Unavailable account", calendarTitle: source.title, timeZone: source.timeZone)
            }
            let drafts = try Self.readAll(EventDraft.self, table: "drafts", db: db).filter { account == nil || $0.calendar?.account == account }
            let mutations = try Self.readAll(Mutation.self, table: "mutations", db: db).filter { $0.state.pending && (account == nil || $0.key.calendar.account == account) }
            let conflicts = try Self.readAll(EventConflict.self, table: "conflicts", db: db).filter { account == nil || $0.mutation.key.calendar.account == account }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(Recovery(created: Date(), sources: sources, drafts: drafts, pendingChanges: mutations, conflicts: conflicts))
        }
    }
    public func removeAccount(_ id: AccountID, discardPending: Bool) throws {
        try database.write { db in
            let pending = try Self.readAll(Mutation.self, table: "mutations", db: db).filter { $0.key.calendar.account == id && $0.state.pending }
            let drafts = try Self.readAll(EventDraft.self, table: "drafts", db: db).filter { $0.calendar?.account == id }
            guard discardPending || (pending.isEmpty && drafts.isEmpty) else { throw CalendarError.invalid("Export or explicitly discard this account's pending changes before disconnecting.") }
            for c in try Self.readAll(CalendarSource.self, table: "calendars", db: db) where c.key.account == id { try Self.purgeRemote(c.key, db) }
            for d in drafts { try Self.closeDraft(d.id, db: db) }
            for m in pending { try db.execute(sql: "DELETE FROM conflicts WHERE id=?", arguments: [m.id]) }
            try db.execute(sql: "DELETE FROM mutations WHERE account=?", arguments: [id.rawValue])
            try db.execute(sql: "DELETE FROM accounts WHERE id=?", arguments: [id.rawValue])
        }; changed()
    }
    public func clearDisconnectedStore() throws {
        try database.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM accounts") == 0 else { throw CalendarError.invalid("Disconnect each account before resetting this store.") }
            try db.execute(sql: "DELETE FROM drafts; DELETE FROM mutations; DELETE FROM conflicts; DELETE FROM preferences; DELETE FROM notification_ledger; DELETE FROM search_documents;")
        }; changed()
    }
    public func search(_ query: String, limit: Int = 200) throws -> Set<String> {
        let terms = query.split(whereSeparator: \.isWhitespace).map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*" }.joined(separator: " AND ")
        guard !terms.isEmpty else { return [] }
        return try database.read { Set(try String.fetchAll($0, sql: "SELECT id FROM search_index WHERE search_index MATCH ? LIMIT ?", arguments: [terms, min(limit, 1000)])) }
    }
    public func ledger() throws -> [String: Data] {
        try database.read { db in Dictionary(uniqueKeysWithValues: try Row.fetchAll(db, sql: "SELECT id,payload FROM notification_ledger").map { ($0["id"] as String, $0["payload"] as Data) }) }
    }
    public func setLedger(_ values: [String: Data]) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM notification_ledger")
            for (id, payload) in values { try db.execute(sql: "INSERT INTO notification_ledger VALUES(?,?)", arguments: [id, payload]) }
        }
    }
    public func evictOccurrenceWindows(keepPerCalendar: Int, protecting: DateInterval) throws {
        try database.write { db in
            let windows = try Self.readAll(CacheCoverage.self, table: "coverage", db: db)
            for (_, group) in Dictionary(grouping: windows, by: \.calendar) {
                let retained = Set(group.sorted { $0.fetched > $1.fetched }.prefix(keepPerCalendar).map(\.id))
                for window in group where !retained.contains(window.id) && !window.interval.overlapsExclusive(protecting) {
                    try db.execute(sql: "DELETE FROM coverage WHERE id=?", arguments: [window.id])
                }
            }
            try db.execute(sql: "DELETE FROM events WHERE kind='occurrence' AND id NOT IN (SELECT event FROM membership)")
            try db.execute(sql: "DELETE FROM search_documents WHERE id NOT IN (SELECT id FROM events)")
        }; changed()
    }
}
