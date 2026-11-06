import Foundation
import GRDB

/// All SQLite access runs on this actor, independently of the UI's MainActor.
public actor CalendarRepository {
    let database: DatabaseQueue
    private var observers: [UUID: AsyncStream<Int>.Continuation] = [:]
    private var revision = 0

    public init(path: String) throws {
        var config = Configuration(); config.foreignKeysEnabled = true
        database = try DatabaseQueue(path: path, configuration: config)
        let version = try database.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        guard version <= AppConfiguration.schemaVersion else { throw CalendarError.incompatibleSchema }
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-local-replica-and-intent") { db in
            try db.execute(sql: """
                CREATE TABLE accounts (id TEXT PRIMARY KEY, subject TEXT NOT NULL, issuer TEXT NOT NULL, payload BLOB NOT NULL, UNIQUE(issuer, subject));
                CREATE TABLE calendars (id TEXT PRIMARY KEY, account TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE, payload BLOB NOT NULL);
                CREATE TABLE events (id TEXT NOT NULL, calendar TEXT NOT NULL REFERENCES calendars(id) ON DELETE CASCADE, kind TEXT NOT NULL, start REAL, end REAL, payload BLOB NOT NULL, PRIMARY KEY(id,kind));
                CREATE INDEX events_range ON events(calendar,kind,start,end);
                CREATE TABLE cursors (calendar TEXT PRIMARY KEY REFERENCES calendars(id) ON DELETE CASCADE, token TEXT NOT NULL, fingerprint TEXT NOT NULL);
                CREATE TABLE staging (run TEXT NOT NULL, id TEXT NOT NULL, calendar TEXT NOT NULL REFERENCES calendars(id) ON DELETE CASCADE, payload BLOB NOT NULL, PRIMARY KEY(run,id));
                CREATE TABLE coverage (id TEXT PRIMARY KEY, calendar TEXT NOT NULL REFERENCES calendars(id) ON DELETE CASCADE, payload BLOB NOT NULL);
                CREATE TABLE membership (window TEXT NOT NULL REFERENCES coverage(id) ON DELETE CASCADE, event TEXT NOT NULL, PRIMARY KEY(window,event));
                CREATE TABLE drafts (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE mutations (id TEXT PRIMARY KEY, account TEXT NOT NULL, event TEXT NOT NULL, state TEXT NOT NULL, created REAL NOT NULL, payload BLOB NOT NULL);
                CREATE INDEX mutation_state ON mutations(state,created);
                CREATE TABLE conflicts (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE preferences (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE notification_ledger (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE VIRTUAL TABLE search_index USING fts5(id UNINDEXED, text, tokenize='unicode61');
                PRAGMA user_version = 1;
                """)
        }
        migrator.registerMigration("v2-indexed-search-documents") { db in
            try db.execute(sql: """
                CREATE TABLE search_documents (id TEXT NOT NULL UNIQUE, text TEXT NOT NULL);
                INSERT INTO search_documents SELECT id,text FROM search_index;
                DROP TABLE search_index;
                CREATE VIRTUAL TABLE search_index USING fts5(id UNINDEXED,text,content='search_documents',content_rowid='rowid',tokenize='unicode61');
                CREATE TRIGGER search_documents_insert AFTER INSERT ON search_documents BEGIN
                    INSERT INTO search_index(rowid,id,text) VALUES(new.rowid,new.id,new.text);
                END;
                CREATE TRIGGER search_documents_delete AFTER DELETE ON search_documents BEGIN
                    INSERT INTO search_index(search_index,rowid,id,text) VALUES('delete',old.rowid,old.id,old.text);
                END;
                CREATE TRIGGER search_documents_update AFTER UPDATE ON search_documents BEGIN
                    INSERT INTO search_index(search_index,rowid,id,text) VALUES('delete',old.rowid,old.id,old.text);
                    INSERT INTO search_index(rowid,id,text) VALUES(new.rowid,new.id,new.text);
                END;
                INSERT INTO search_index(search_index) VALUES('rebuild');
                PRAGMA user_version = 2;
                """)
        }
        migrator.registerMigration("v3-visible-range-index") { db in
            try db.execute(sql: "CREATE INDEX events_visible_range ON events(start,end); PRAGMA user_version = 3;")
        }
        migrator.registerMigration("v4-series-tombstones") { db in
            try db.execute(sql: """
                ALTER TABLE events ADD COLUMN series TEXT;
                ALTER TABLE events ADD COLUMN cancelled INTEGER NOT NULL DEFAULT 0;
                UPDATE events SET series=json_extract(CAST(payload AS TEXT),'$.raw.recurringEventId'), cancelled=COALESCE(json_extract(CAST(payload AS TEXT),'$.raw.status')='cancelled',0);
                CREATE INDEX events_series ON events(calendar,series,kind);
                PRAGMA user_version = 4;
                """)
        }
        migrator.registerMigration("v5-closed-drafts") { db in
            try db.execute(sql: "CREATE TABLE closed_drafts (id TEXT PRIMARY KEY, closed REAL NOT NULL); PRAGMA user_version = 5;")
        }
        try migrator.migrate(database)
        // A crash or task cancellation cannot establish that a remote write was not applied.
        try database.write { db in
            for var work in try Self.readAll(Mutation.self, table: "mutations", db: db) where work.state == .executing {
                work.state = .uncertain; try Self.putMutation(work, db)
            }
            try db.execute(sql: "DELETE FROM staging")
        }
    }

    public func changes() -> AsyncStream<Int> {
        let id = UUID()
        return AsyncStream { continuation in
            observers[id] = continuation; continuation.yield(revision)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
    func changed() { revision += 1; for c in observers.values { c.yield(revision) } }
    static func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    static func readAll<T: Decodable>(_ type: T.Type, table: String, db: Database) throws -> [T] {
        try Row.fetchAll(db, sql: "SELECT payload FROM \(table)").map { try JSONDecoder().decode(type, from: $0["payload"] as Data) }
    }
    static func decode<T: Decodable>(_ type: T.Type, row: Row?) throws -> T? {
        guard let row else { return nil }; return try JSONDecoder().decode(type, from: row["payload"] as Data)
    }
    static func put<T: Encodable>(_ value: T, id: String, table: String, db: Database) throws {
        try db.execute(sql: "INSERT INTO \(table)(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", arguments: [id, try encode(value)])
    }
    static func putAccount(_ a: CalendarAccount, _ db: Database) throws {
        try db.execute(sql: "INSERT INTO accounts VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET subject=excluded.subject,issuer=excluded.issuer,payload=excluded.payload", arguments: [a.id.rawValue, a.subject, a.issuer, try encode(a)])
    }
    static func putCalendar(_ c: CalendarSource, _ db: Database) throws {
        try db.execute(sql: "INSERT INTO calendars VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", arguments: [c.id, c.key.account.rawValue, try encode(c)])
    }
    static func putMutation(_ m: Mutation, _ db: Database) throws {
        try db.execute(sql: "INSERT INTO mutations VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET state=excluded.state,payload=excluded.payload", arguments: [m.id, m.key.calendar.account.rawValue, m.key.id, m.state.rawValue, m.created.timeIntervalSince1970, try encode(m)])
    }
    static func putEvent(_ e: CalendarEvent, kind: String, _ db: Database) throws {
        if let master = e.masterID {
            let masterKey = EventKey(calendar: e.key.calendar, eventID: master).id
            if try Int.fetchOne(db, sql: "SELECT cancelled FROM events WHERE kind='resource' AND id=?", arguments: [masterKey]) == 1 { return }
        }
        if kind == "occurrence" {
            let masterKey = e.masterID.map { EventKey(calendar: e.key.calendar, eventID: $0).id } ?? e.id
            let cancelled = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM events WHERE kind='resource' AND cancelled=1 AND id IN (?,?)", arguments: [e.id, masterKey]) ?? 0
            if cancelled > 0 { return }
        }
        let interval = e.time?.interval(in: TimeZone(identifier: e.calendarZone) ?? .gmt)
        try db.execute(sql: "INSERT INTO events(id,calendar,kind,start,end,payload,series,cancelled) VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(id,kind) DO UPDATE SET start=excluded.start,end=excluded.end,payload=excluded.payload,series=excluded.series,cancelled=excluded.cancelled", arguments: [e.id, e.key.calendar.id, kind, interval?.start.timeIntervalSince1970, interval?.end.timeIntervalSince1970, try encode(e), e.masterID, e.cancelled])
        if e.cancelled {
            try db.execute(sql: "DELETE FROM events WHERE calendar=? AND kind='occurrence' AND (id=? OR series=?)", arguments: [e.key.calendar.id, e.id, e.key.eventID])
            if e.masterID == nil { try db.execute(sql: "DELETE FROM events WHERE calendar=? AND series=?", arguments: [e.key.calendar.id, e.key.eventID]) }
        }
        if !e.cancelled && !e.redacted {
            let guests = e.attendees.map { $0.text("email") }.joined(separator: " ")
            let searchable = [e.title, e.location, e.plainDescription, guests, e.raw["organizer"]?["email"].string ?? ""].joined(separator: " ")
            try db.execute(sql: "INSERT INTO search_documents(id,text) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET text=excluded.text WHERE text != excluded.text", arguments: [e.id, String(searchable.prefix(100_000))])
        } else { try db.execute(sql: "DELETE FROM search_documents WHERE id=?", arguments: [e.id]) }
    }
    static func calendar(_ key: CalendarKey, _ db: Database) throws -> CalendarSource? { try decode(CalendarSource.self, row: Row.fetchOne(db, sql: "SELECT payload FROM calendars WHERE id=?", arguments: [key.id])) }
    static func account(_ id: AccountID, _ db: Database) throws -> CalendarAccount? { try decode(CalendarAccount.self, row: Row.fetchOne(db, sql: "SELECT payload FROM accounts WHERE id=?", arguments: [id.rawValue])) }

    public func accounts() throws -> [CalendarAccount] { try database.read { try Self.readAll(CalendarAccount.self, table: "accounts", db: $0).sorted { $0.label < $1.label } } }
    public func calendars() throws -> [CalendarSource] { try database.read { try Self.readAll(CalendarSource.self, table: "calendars", db: $0).sorted { $0.title < $1.title } } }
    public func coverage(for key: CalendarKey) throws -> [CacheCoverage] { try database.read { db in try Row.fetchAll(db, sql: "SELECT payload FROM coverage WHERE calendar=?", arguments: [key.id]).map { try JSONDecoder().decode(CacheCoverage.self, from: $0["payload"] as Data) } } }
    public func account(_ id: AccountID) throws -> CalendarAccount? { try database.read { try Self.account(id, $0) } }
    public func calendar(_ key: CalendarKey) throws -> CalendarSource? { try database.read { try Self.calendar(key, $0) } }
    @discardableResult public func connect(_ incoming: CalendarAccount, expected: AccountID? = nil) throws -> CalendarAccount {
        let result = try database.write { db in
            let previous = try Self.readAll(CalendarAccount.self, table: "accounts", db: db).first { $0.issuer == incoming.issuer && $0.subject == incoming.subject }
            if let expected, previous?.id != expected { throw CalendarError.invalid("You selected a different Google account. Reconnect the original account to keep its pending changes.") }
            var account = incoming
            if let previous { account.id = previous.id; account.label = previous.label; account.generation = previous.generation + 1 }
            try Self.putAccount(account, db); return account
        }; changed(); return result
    }
    public func updateAccount(_ account: CalendarAccount) throws {
        try database.write { db in
            guard try Self.account(account.id, db) != nil else { throw CalendarError.missing }
            try Self.putAccount(account, db)
        }; changed()
    }
    public func setAccountStatus(_ id: AccountID, _ status: AccountStatus, success: Date? = nil, generation: Int? = nil) throws {
        try database.write { db in
            guard var a = try Self.account(id, db), generation == nil || a.generation == generation else { return }; a.status = status
            if let success { a.lastSync = success; a.retryAfter = nil; a.consecutiveFailures = 0 }; try Self.putAccount(a, db)
        }; changed()
    }
    public func recordSyncFailure(_ account: CalendarAccount, status: AccountStatus, now: Date, minimumDelay: TimeInterval = 0, jitter: TimeInterval = 0) throws {
        try database.write { db in
            guard var a = try Self.account(account.id, db), a.generation == account.generation else { return }
            let count = min(12, (a.consecutiveFailures ?? 0) + 1)
            a.status = status; a.consecutiveFailures = count
            a.retryAfter = now.addingTimeInterval(max(minimumDelay, min(3600, pow(2, Double(count))) + max(0, jitter)))
            try Self.putAccount(a, db)
        }; changed()
    }
    public func recordCalendarSync(_ source: CalendarSource, success: Date? = nil, error: String? = nil) throws {
        try database.write { db in
            guard var c = try Self.calendar(source.key, db), c.generation == source.generation else { return }
            if let success { c.lastSync = success }; c.lastError = error; try Self.putCalendar(c, db)
        }; changed()
    }
    public func setAccountLabel(_ id: AccountID, label: String) throws {
        try database.write { db in
            guard var a = try Self.account(id, db) else { throw CalendarError.missing }
            let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
            a.label = trimmed.isEmpty ? a.email : String(trimmed.prefix(200)); try Self.putAccount(a, db)
        }; changed()
    }
    public func reconcileCalendars(_ sources: [CalendarSource], account: AccountID, generation: Int) throws {
        try database.write { db in
            guard try Self.account(account, db)?.generation == generation else { throw CalendarError.staleGeneration }
            let existing = try Self.readAll(CalendarSource.self, table: "calendars", db: db).filter { $0.key.account == account }
            let incomingIDs = Set(sources.map(\.id))
            for var missing in existing where !incomingIDs.contains(missing.id) {
                missing.deleted = true; missing.generation += 1; try Self.putCalendar(missing, db); try Self.purgeRemote(missing.key, db); try Self.sanitizeLocalBaselines(for: missing, db)
            }
            for var source in sources {
                guard source.key.account == account, source.key.calendarID != "primary" else { throw CalendarError.invalid("The provider returned an invalid calendar identity.") }
                if let old = existing.first(where: { $0.id == source.id }) {
                    source.visible = old.visible; source.syncEnabled = old.syncEnabled; source.generation = old.generation; source.writeEpoch = old.writeEpoch
                    source.lastSync = old.lastSync; source.lastError = old.lastError
                    if old.role != source.role || old.deleted != source.deleted {
                        source.generation += 1; try Self.purgeRemote(source.key, db); try Self.sanitizeLocalBaselines(for: source, db)
                    }
                }
                try Self.putCalendar(source, db)
            }
        }; changed()
    }
    static func purgeRemote(_ key: CalendarKey, _ db: Database) throws {
        try db.execute(sql: "DELETE FROM search_documents WHERE id IN (SELECT id FROM events WHERE calendar=?)", arguments: [key.id])
        for table in ["events", "cursors", "coverage", "staging"] { try db.execute(sql: "DELETE FROM \(table) WHERE calendar=?", arguments: [key.id]) }
    }
    static func sanitizeLocalBaselines(for source: CalendarSource, _ db: Database) throws {
        func protected(_ event: CalendarEvent?) -> Bool {
            !source.readable || source.deleted || (source.role == "writerWithoutPrivateAccess" && event?.raw.text("visibility") == "private")
        }
        for var work in try Self.readAll(Mutation.self, table: "mutations", db: db) where work.key.calendar == source.key {
            if protected(work.base) {
                work.base = work.base?.redactingDetails(); work.confirmedEvent = work.confirmedEvent?.redactingDetails()
                if work.state.pending { work.state = .failed; work.errorCategory = "permission" }
                try Self.putMutation(work, db)
            }
        }
        for var conflict in try Self.readAll(EventConflict.self, table: "conflicts", db: db) where conflict.mutation.key.calendar == source.key {
            if protected(conflict.remote) || protected(conflict.mutation.base) {
                conflict.remote = conflict.remote?.redactingDetails(); conflict.mutation.base = conflict.mutation.base?.redactingDetails()
                try Self.put(conflict, id: conflict.id, table: "conflicts", db: db)
            }
        }
        for var draft in try Self.readAll(EventDraft.self, table: "drafts", db: db) where draft.calendar == source.key {
            if let base = draft.source, protected(base) {
                // Keep only user-changed fields; discard copies of newly forbidden remote data.
                draft.fields = draft.fields.filter { base.raw[$0.key] != $0.value && !$0.key.hasPrefix("dayfold") }
                draft.source = base.redactingDetails(); draft.requiresOnlineReview = true
                try Self.put(draft, id: draft.id, table: "drafts", db: db)
            }
        }
    }
    public func markCoverageStale(_ source: CalendarSource) throws {
        try database.write { db in
            guard try Self.calendar(source.key, db)?.generation == source.generation else { return }
            try Self.staleWindows(source.key, db)
        }; changed()
    }
    public func setCalendarChoices(_ key: CalendarKey, visible: Bool? = nil, syncEnabled: Bool? = nil) throws {
        try database.write { db in
            guard var c = try Self.calendar(key, db) else { throw CalendarError.missing }
            if let visible { c.visible = visible }; if let syncEnabled { c.syncEnabled = syncEnabled; c.generation += 1 }
            try Self.putCalendar(c, db)
        }; changed()
    }
    public func preferences() throws -> Preferences { try database.read { try Self.decode(Preferences.self, row: Row.fetchOne($0, sql: "SELECT payload FROM preferences WHERE id='main'")) ?? Preferences() } }
    public func setPreferences(_ p: Preferences) throws { try database.write { try Self.put(p, id: "main", table: "preferences", db: $0) }; changed() }
    public func saveDraft(_ draft: EventDraft) throws {
        try database.write { db in
            if let closed = try Double.fetchOne(db, sql: "SELECT closed FROM closed_drafts WHERE id=?", arguments: [draft.id]),
               draft.id != "quick-entry-text" || draft.updated.timeIntervalSince1970 <= closed { return }
            let old = try Self.decode(EventDraft.self, row: Row.fetchOne(db, sql: "SELECT payload FROM drafts WHERE id=?", arguments: [draft.id]))
            guard old == nil || old!.updated <= draft.updated else { return }
            // A delayed autosave must not recreate a draft after its mutation was queued.
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mutations WHERE id=?", arguments: [draft.id]) == 0 else { return }
            var safe = draft
            if let base = draft.source {
                let source = try Self.calendar(base.key.calendar, db)
                if source == nil || source?.deleted == true || source?.readable == false || (source?.role == "writerWithoutPrivateAccess" && base.raw.text("visibility") == "private") {
                    safe.fields = draft.fields.filter { base.raw[$0.key] != $0.value && !$0.key.hasPrefix("dayfold") }
                    safe.source = base.redactingDetails(); safe.requiresOnlineReview = true
                }
            }
            try Self.put(safe, id: safe.id, table: "drafts", db: db)
        }; changed()
    }
    static func closeDraft(_ id: String, at date: Date = Date(), db: Database) throws {
        try db.execute(sql: "INSERT INTO closed_drafts VALUES(?,?) ON CONFLICT(id) DO UPDATE SET closed=MAX(closed,excluded.closed)", arguments: [id, date.timeIntervalSince1970])
        try db.execute(sql: "DELETE FROM drafts WHERE id=?", arguments: [id])
    }
    public func discardDraft(_ id: String, at date: Date = Date()) throws { try database.write { try Self.closeDraft(id, at: date, db: $0) }; changed() }
    public func mutations() throws -> [Mutation] { try database.read { try Self.readAll(Mutation.self, table: "mutations", db: $0).sorted { $0.created < $1.created } } }
    public func mutation(_ id: String) throws -> Mutation? { try database.read { try Self.decode(Mutation.self, row: Row.fetchOne($0, sql: "SELECT payload FROM mutations WHERE id=?", arguments: [id])) } }
    public func cursor(_ key: CalendarKey, fingerprint: String) throws -> String? {
        try database.read { try String.fetchOne($0, sql: "SELECT token FROM cursors WHERE calendar=? AND fingerprint=?", arguments: [key.id, fingerprint]) }
    }
    public func clearCursor(_ key: CalendarKey) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM cursors WHERE calendar=?", arguments: [key.id]); try Self.staleWindows(key, db)
        }; changed()
    }
    static func staleWindows(_ key: CalendarKey, _ db: Database) throws {
        for var c in try Self.readAll(CacheCoverage.self, table: "coverage", db: db) where c.calendar == key {
            c.stale = true
            try db.execute(sql: "UPDATE coverage SET payload=? WHERE id=?", arguments: [try encode(c), c.id])
        }
    }
    public func stage(_ events: [CalendarEvent], run: String, source: CalendarSource) throws {
        try database.write { db in
            guard let current = try Self.calendar(source.key, db), current.generation == source.generation, current.writeEpoch == source.writeEpoch else { throw CalendarError.staleGeneration }
            for event in events {
                guard event.key.calendar == source.key, event.raw.text("id") == event.key.eventID else { throw CalendarError.invalid("A provider response crossed calendar identities.") }
                let safe = source.freeBusyOnly || (source.role == "writerWithoutPrivateAccess" && event.raw.text("visibility") == "private") ? event.redactingDetails() : event
                try db.execute(sql: "INSERT INTO staging VALUES(?,?,?,?) ON CONFLICT(run,id) DO UPDATE SET payload=excluded.payload", arguments: [run, event.id, source.id, try Self.encode(safe)])
            }
        }
    }
    public func abandonStage(_ run: String) throws { try database.write { try $0.execute(sql: "DELETE FROM staging WHERE run=?", arguments: [run]) } }
    public func publish(run: String, source: CalendarSource, token: String? = nil, fingerprint: String = "", replaceResources: Bool = false, window: DateInterval? = nil, fetched: Date = Date()) throws {
        try database.write { db in
            guard let current = try Self.calendar(source.key, db), current.generation == source.generation, current.writeEpoch == source.writeEpoch, !current.deleted, current.syncEnabled else { throw CalendarError.staleGeneration }
            let kind = window == nil ? "resource" : "occurrence"
            if replaceResources { try db.execute(sql: "DELETE FROM events WHERE calendar=? AND kind='resource'", arguments: [source.id]) }
            var windowID: String?
            if let window {
                let id = source.id + ":" + String(window.start.timeIntervalSince1970) + ":" + String(window.end.timeIntervalSince1970)
                windowID = id
                let coverage = CacheCoverage(id: id, calendar: source.key, interval: window, fetched: fetched, generation: source.generation, writeEpoch: source.writeEpoch, stale: false)
                try db.execute(sql: "INSERT INTO coverage VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload", arguments: [id, source.id, try Self.encode(coverage)])
                // Remove old membership only at complete publication; orphan occurrences are evicted below.
                try db.execute(sql: "DELETE FROM membership WHERE window=?", arguments: [id])
            }
            // Stream staged rows; memory is bounded independently of the baseline size.
            let cursor = try Row.fetchCursor(db, sql: "SELECT payload FROM staging WHERE run=?", arguments: [run])
            while let row = try cursor.next() {
                let event = try JSONDecoder().decode(CalendarEvent.self, from: row["payload"] as Data)
                try Self.putEvent(event, kind: kind, db)
                if let windowID { try db.execute(sql: "INSERT OR IGNORE INTO membership VALUES(?,?)", arguments: [windowID, event.id]) }
                if event.cancelled { // Minimal tombstones still suppress any older expanded instance.
                    try db.execute(sql: "DELETE FROM events WHERE id=? AND kind='occurrence'", arguments: [event.id])
                }
            }
            if windowID != nil {
                try db.execute(sql: "DELETE FROM events WHERE calendar=? AND kind='occurrence' AND id NOT IN (SELECT event FROM membership)", arguments: [source.id])
            } else {
                guard let token, !token.isEmpty else { throw CalendarError.invalid("Google did not return a complete sync cursor.") }
                try db.execute(sql: "INSERT INTO cursors VALUES(?,?,?) ON CONFLICT(calendar) DO UPDATE SET token=excluded.token,fingerprint=excluded.fingerprint", arguments: [source.id, token, fingerprint])
                try Self.staleWindows(source.key, db)
            }
            try db.execute(sql: "DELETE FROM staging WHERE run=?", arguments: [run])
            try db.execute(sql: "DELETE FROM search_documents WHERE id NOT IN (SELECT id FROM events)")
        }; changed()
    }

    public func event(_ key: EventKey) throws -> CalendarEvent? {
        try database.read { try Self.decode(CalendarEvent.self, row: Row.fetchOne($0, sql: "SELECT payload FROM events WHERE id=? ORDER BY kind LIMIT 1", arguments: [key.id])) }
    }
    public func snapshot(interval: DateInterval, displayZone: TimeZone) throws -> RepositorySnapshot {
        try database.read { db in
            let accounts = try Self.readAll(CalendarAccount.self, table: "accounts", db: db)
            let calendars = try Self.readAll(CalendarSource.self, table: "calendars", db: db)
            // Padding is for civil dates indexed in a source zone. Final overlap uses the display zone.
            let rows = try Row.fetchAll(db, sql: "SELECT payload,kind FROM events WHERE start <= ? AND end >= ? ORDER BY kind DESC", arguments: [interval.end.addingTimeInterval(172800).timeIntervalSince1970, interval.start.addingTimeInterval(-172800).timeIntervalSince1970])
            var events: [String: CalendarEvent] = [:]
            for row in rows {
                let e = try JSONDecoder().decode(CalendarEvent.self, from: row["payload"] as Data)
                if row["kind"] as String == "resource" && !e.recurrence.isEmpty { continue }
                events[e.id] = e
            }
            let work = try Self.readAll(Mutation.self, table: "mutations", db: db).sorted { $0.created < $1.created }
            for m in work where m.state.pending {
                guard let source = calendars.first(where: { $0.key == m.key.calendar }), source.readable, !source.deleted else { continue }
                if m.kind == .delete { events[m.key.id] = nil; continue }
                var projected = events[m.key.id] ?? m.base ?? CalendarEvent(key: m.key, raw: ["id": .string(m.key.eventID)], calendarZone: source.timeZone)
                // Never repopulate forbidden remote details from pending intent.
                if projected.redacted || (source.role == "writerWithoutPrivateAccess" && projected.raw.text("visibility") == "private") { continue }
                if m.kind == .rsvp, let response = m.fields["attendees"]?.array?.first?["responseStatus"] {
                    projected.raw["attendees"] = .array(projected.attendees.map { var attendee = $0; if attendee.flag("self") { attendee["responseStatus"] = response }; return .object(attendee) })
                } else { projected.raw.merge(m.fields) { _, local in local } }
                projected.localState = m.state; events[m.key.id] = projected
            }
            let selected = events.values.compactMap { e -> (CalendarEvent, Date)? in
                guard !e.cancelled, let t = e.time else { return nil }
                let range = t.interval(in: displayZone)
                let overlaps = range.duration == 0 ? interval.start <= range.start && range.start < interval.end : range.overlapsExclusive(interval)
                return overlaps ? (e, range.start) : nil
            }.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 < $1.1 }.map(\.0)
            return RepositorySnapshot(accounts: accounts, calendars: calendars, events: selected, mutations: work.filter { $0.state.pending }, drafts: try Self.readAll(EventDraft.self, table: "drafts", db: db), conflicts: try Self.readAll(EventConflict.self, table: "conflicts", db: db), coverage: try Self.readAll(CacheCoverage.self, table: "coverage", db: db), recentChanges: Array(work.reversed().filter { $0.state == .confirmed && $0.reversedBy == nil }.prefix(20)))
        }
    }
}
