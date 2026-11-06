import Foundation

public struct DemoDataset: Codable, Sendable {
    public var accounts: [CalendarAccount]
    public var calendars: [CalendarSource]
    public var events: [CalendarEvent]
}
public enum FixtureFactory {
    public static func demo(now: Date = Date(), accountCount: Int = 3, calendarsPerAccount: Int = 2, eventCount: Int = 120) -> DemoDataset {
        let labels = ["Work", "Personal", "Studio", "Community", "Client"]
        let colors = ["#5578C5", "#C37A4D", "#8C6BB5", "#518B79", "#A47E3B"]
        var accounts: [CalendarAccount] = [], calendars: [CalendarSource] = []
        for i in 0..<accountCount {
            let a = CalendarAccount(id: AccountID(rawValue: "demo-account-\(i)"), subject: "demo-subject-\(i)", email: "\(labels[i % labels.count].lowercased())@example.com", label: labels[i % labels.count], scopes: GoogleScope.all, isDemo: true)
            accounts.append(a)
            for j in 0..<calendarsPerAccount {
                var c = CalendarSource(key: CalendarKey(account: a.id, calendarID: "demo-calendar-\(i)-\(j)@example.com"), title: j == 0 ? labels[i % labels.count] : "\(labels[i % labels.count]) shared", timeZone: "Africa/Lagos", role: j == 0 ? "owner" : "reader", color: colors[i % colors.count], primary: j == 0)
                c.allowsMeet = j == 0; calendars.append(c)
            }
        }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "Africa/Lagos")!; cal.firstWeekday = 2
        let week = cal.dateInterval(of: .weekOfYear, for: now)!.start
        let titles = ["Weekly planning", "Design critique", "Focus · Dayfold", "Product sync", "Lunch with Sam", "Project review", "Evening run", "Reading hour", "Coffee & ideas", "Customer research", "Release checklist", "Studio catch-up"]
        var events: [CalendarEvent] = []
        for i in 0..<eventCount {
            let source = calendars[(i / 3) % calendars.count]
            let horizon = eventCount > 1000 ? 3650 : 21
            let dayOffset = i % horizon - horizon / 3
            let day = cal.date(byAdding: .day, value: dayOffset, to: week)!
            let start = cal.date(bySettingHour: 8 + (i * 3 % 10), minute: i % 3 == 0 ? 30 : 0, second: 0, of: day)!
            let id = String(format: "de%030x", i)
            var raw: JSONObject = ["id": .string(id), "summary": .string(titles[i % titles.count]), "etag": .string("\"demo-\(i)\""), "eventType": .string("default"), "status": .string("confirmed"), "organizer": .object(["self": .bool(true), "email": .string(accounts.first { $0.id == source.key.account }!.email)]), "location": .string(i % 4 == 0 ? "Studio · Meeting room" : ""), "description": .string("Fictional demo event. Changes stay in the isolated demo store."), "reminders": .object(["useDefault": .bool(true)])]
            let time: EventTime = i % 23 == 0 ? .allDay(start: LocalDate(day, zone: cal.timeZone), end: LocalDate(day, zone: cal.timeZone).adding(days: i % 2 + 1)) : .timed(start: start, end: start.addingTimeInterval(Double(30 + (i % 3) * 30) * 60), startZone: source.timeZone, endZone: source.timeZone)
            raw.merge(time.providerFields) { _, v in v }
            if i % 19 == 0 {
                raw["organizer"] = .object(["email": .string("alex@example.com"), "self": .bool(false)])
                raw["attendees"] = .array([.object(["email": .string(accounts.first { $0.id == source.key.account }!.email), "self": .bool(true), "responseStatus": .string("needsAction")]), .object(["email": .string("alex@example.com"), "organizer": .bool(true), "responseStatus": .string("accepted")])])
            }
            events.append(CalendarEvent(key: EventKey(calendar: source.key, eventID: id), raw: raw, calendarZone: source.timeZone))
        }
        return DemoDataset(accounts: accounts, calendars: calendars, events: events)
    }
}

/// A deterministic fake, exclusively used by explicitly selected demo mode and tests.
public actor DemoProvider: CalendarProvider {
    private var data: DemoDataset
    private let file: URL?
    private var offline = false
    private var failures: [ProviderError] = []
    private var loseNextWrite = false
    private var version = 1000
    public var pageSize: Int
    public private(set) var writeCount = 0
    public init(dataset: DemoDataset, file: URL? = nil, pageSize: Int = 200) throws {
        self.file = file; self.pageSize = pageSize
        if let file, FileManager.default.fileExists(atPath: file.path) { data = try JSONDecoder().decode(DemoDataset.self, from: Data(contentsOf: file)) } else { data = dataset }
    }
    public func setOffline(_ value: Bool) { offline = value }
    public func failNext(_ error: ProviderError) { failures.append(error) }
    public func loseNextWriteResponse() { loseNextWrite = true }
    public func remoteEdit(_ key: EventKey, fields: JSONObject) throws {
        guard let index = data.events.firstIndex(where: { $0.key == key }) else { throw ProviderError.missing }
        data.events[index].raw.merge(fields) { _, v in v }; version += 1; data.events[index].raw["etag"] = .string("\"demo-\(version)\"")
        try persist()
    }
    private func check() throws { if offline { throw ProviderError.network }; if !failures.isEmpty { throw failures.removeFirst() } }
    private func persist() throws { if let file { try JSONEncoder().encode(data).write(to: file, options: .atomic) } }
    private func page<T: Sendable>(_ items: [T], token: String?, sync: String? = nil) -> ProviderPage<T> {
        let offset = Int(token ?? "0") ?? 0, end = min(items.count, (Int(token ?? "0") ?? 0) + pageSize)
        return ProviderPage(items: offset < end ? Array(items[offset..<end]) : [], nextPage: end < items.count ? String(end) : nil, syncToken: end >= items.count ? sync : nil)
    }
    public func calendars(account: AccountID, page: String?) async throws -> ProviderPage<CalendarSource> { try check(); return self.page(data.calendars.filter { $0.key.account == account }, token: page) }
    public func events(source: CalendarSource, query: EventQuery, page: String?) async throws -> ProviderPage<CalendarEvent> {
        try check()
        var events = data.events.filter { $0.key.calendar == source.key }
        if case .occurrences(let interval) = query {
            events = events.filter { !$0.cancelled && ($0.time?.interval(in: TimeZone(identifier: source.timeZone) ?? .gmt).overlapsExclusive(interval) ?? false) }
            // Fake recurring writes expose their first slot only. No local expansion is used by Google mode.
            events = events.map { e in
                guard !e.recurrence.isEmpty else { return e }
                var instance = e; instance.raw["recurrence"] = nil; instance.raw["recurringEventId"] = .string(e.key.eventID); instance.raw["originalStartTime"] = e.raw["start"]; return instance
            }
        }
        return self.page(events, token: page, sync: "demo-\(version)")
    }
    public func event(_ key: EventKey, zone: String) async throws -> CalendarEvent {
        try check(); guard let e = data.events.first(where: { $0.key == key && !$0.cancelled }) else { throw ProviderError.missing }; return e
    }
    public func write(_ mutation: Mutation, etag: String?, zone: String) async throws -> CalendarEvent? {
        try check(); writeCount += 1; version += 1
        let index = data.events.firstIndex { $0.key == mutation.key }
        if mutation.kind == .create && index != nil { throw ProviderError.duplicate }
        if mutation.kind != .create {
            guard let index else { throw ProviderError.missing }
            guard etag == data.events[index].etag else { throw ProviderError.conflict }
        }
        var result: CalendarEvent?
        if mutation.kind == .delete {
            data.events[index!].raw["status"] = .string("cancelled")
        } else {
            var e = index.map { data.events[$0] } ?? CalendarEvent(key: mutation.key, raw: ["id": .string(mutation.key.eventID), "organizer": .object(["self": .bool(true)])], calendarZone: zone)
            if mutation.kind == .rsvp {
                let status = mutation.fields["attendees"]?.array?.first?["responseStatus"] ?? .string("needsAction")
                e.raw["attendees"] = .array(e.attendees.map { var a = $0; if a.flag("self") { a["responseStatus"] = status }; return .object(a) })
            } else { e.raw.merge(mutation.fields) { _, v in v } }
            e.raw["etag"] = .string("\"demo-\(version)\""); e.raw["status"] = .string("confirmed")
            if let index { data.events[index] = e } else { data.events.append(e) }; result = e
        }
        try persist()
        if loseNextWrite { loseNextWrite = false; throw ProviderError.network }
        return result
    }
    public func busy(source: CalendarSource, window: DateInterval) async throws -> [CalendarEvent] { try await events(source: source, query: .occurrences(window), page: nil).items.map { $0.redactingDetails() } }
}
