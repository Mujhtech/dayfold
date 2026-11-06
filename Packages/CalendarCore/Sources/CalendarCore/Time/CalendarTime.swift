import Foundation

public struct LocalDate: Hashable, Codable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int
    public init(year: Int, month: Int, day: Int) throws {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = c.date(from: parts), c.component(.year, from: date) == year,
              c.component(.month, from: date) == month, c.component(.day, from: date) == day else { throw CalendarError.invalid("Invalid calendar date.") }
        self.year = year; self.month = month; self.day = day
    }
    public init(_ string: String) throws {
        let p = string.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { throw CalendarError.invalid("Use YYYY-MM-DD for a date.") }
        try self.init(year: p[0], month: p[1], day: p[2])
    }
    public init(_ date: Date, zone: TimeZone) {
        var c = Calendar(identifier: .gregorian); c.timeZone = zone
        year = c.component(.year, from: date); month = c.component(.month, from: date); day = c.component(.day, from: date)
    }
    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.description < rhs.description }
    public func start(in zone: TimeZone) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = zone
        return c.date(from: DateComponents(year: year, month: month, day: day))!
    }
    public func adding(days: Int) -> Self {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!
        return Self(c.date(byAdding: .day, value: days, to: start(in: c.timeZone))!, zone: c.timeZone)
    }
}

public enum EventTime: Codable, Equatable, Sendable {
    case timed(start: Date, end: Date, startZone: String, endZone: String)
    case allDay(start: LocalDate, end: LocalDate)
    public func interval(in zone: TimeZone) -> DateInterval {
        switch self {
        case .timed(let s, let e, _, _): DateInterval(start: s, end: max(s, e))
        case .allDay(let s, let e): DateInterval(start: s.start(in: zone), end: max(s.start(in: zone), e.start(in: zone)))
        }
    }
    public var isAllDay: Bool { if case .allDay = self { true } else { false } }
    public var providerFields: JSONObject {
        switch self {
        case .timed(let s, let e, let sz, let ez):
            ["start": .object(["dateTime": .string(InternetDate.string(s)), "timeZone": .string(sz)]), "end": .object(["dateTime": .string(InternetDate.string(e)), "timeZone": .string(ez)])]
        case .allDay(let s, let e): ["start": .object(["date": .string(s.description)]), "end": .object(["date": .string(e.description)])]
        }
    }
    public static func decode(_ raw: JSONObject, calendarZone: String) -> Self? {
        let s = raw["start"] ?? .null, e = raw["end"] ?? .null
        if let sd = s["date"].string, let ed = e["date"].string, let start = try? LocalDate(sd), let end = try? LocalDate(ed) { return .allDay(start: start, end: end) }
        if let sd = s["dateTime"].string, let ed = e["dateTime"].string, let start = InternetDate.parse(sd), let end = InternetDate.parse(ed) {
            return .timed(start: start, end: end, startZone: s["timeZone"].string ?? calendarZone, endZone: e["timeZone"].string ?? calendarZone)
        }
        return nil
    }
}

public enum InternetDate {
    private static let wholeSeconds = Date.ISO8601FormatStyle()
    private static let fractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    public static func parse(_ s: String) -> Date? {
        // Value format styles are Sendable and reuse Foundation's formatter cache.
        // Creating a class formatter for every comparison dominated dense calendar queries.
        (try? wholeSeconds.parse(s)) ?? (try? fractionalSeconds.parse(s))
    }
    public static func string(_ date: Date) -> String { wholeSeconds.format(date) }
}

public enum WallTime {
    /// Zero results means a spring gap; two means a repeated hour requiring an explicit choice.
    public static func candidates(day: LocalDate, hour: Int, minute: Int, zone: TimeZone) -> [Date] {
        guard (0..<24).contains(hour), (0..<60).contains(minute) else { return [] }
        var c = Calendar(identifier: .gregorian); c.timeZone = zone
        let parts = DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute, second: 0)
        var utc = Calendar(identifier: .gregorian); utc.timeZone = .gmt
        guard let wall = utc.date(from: parts) else { return [] }
        // Enumerate the zone offsets around the civil date, then validate the resulting
        // components. This also handles half-hour repeats that Calendar.nextDate can miss.
        let offsets = Set(stride(from: -48, through: 48, by: 6).map { zone.secondsFromGMT(for: wall.addingTimeInterval(Double($0) * 3600)) })
        return offsets.compactMap { offset -> Date? in
            let instant = wall.addingTimeInterval(Double(-offset))
            let actual = c.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
            return actual.year == day.year && actual.month == day.month && actual.day == day.day && actual.hour == hour && actual.minute == minute && actual.second == 0 ? instant : nil
        }.sorted()
    }
}

public extension DateInterval {
    func overlapsExclusive(_ other: DateInterval) -> Bool { start < other.end && end > other.start }
}
