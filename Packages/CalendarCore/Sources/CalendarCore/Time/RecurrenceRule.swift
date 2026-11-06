import Foundation

public struct RecurrenceRule: Equatable, Sendable {
    public enum Frequency: String, CaseIterable, Sendable { case daily = "DAILY", weekly = "WEEKLY", monthly = "MONTHLY", yearly = "YEARLY" }
    public var frequency: Frequency
    public var interval: Int = 1
    public var weekdays: [String] = []
    public var monthDay: Int?
    public var ordinal: Int?
    public var count: Int?
    public var until: LocalDate?
    public init(frequency: Frequency) { self.frequency = frequency }
    public static func supportsStructuralEdit(_ lines: [String]) -> Bool {
        guard lines.count == 1, lines[0].hasPrefix("RRULE:") else { return false }
        let parts = lines[0].dropFirst(6).split(separator: ";").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
        guard parts.allSatisfy({ $0.count == 2 }) else { return false }
        let allowed: Set<String> = ["FREQ", "INTERVAL", "BYDAY", "BYMONTHDAY", "COUNT", "UNTIL"]
        guard parts.allSatisfy({ allowed.contains($0[0]) }), Set(parts.map { $0[0] }).count == parts.count,
              let frequencyText = parts.first(where: { $0[0] == "FREQ" })?[1], let frequency = Frequency(rawValue: frequencyText) else { return false }
        let dayRule = parts.first(where: { $0[0] == "BYDAY" })?[1], monthDay = parts.first(where: { $0[0] == "BYMONTHDAY" })?[1]
        if let monthDay, frequency != .monthly || Int(monthDay).map({ !(1...31).contains($0) }) != false { return false }
        if let dayRule {
            if frequency == .weekly {
                guard dayRule.split(separator: ",").allSatisfy({ ["MO", "TU", "WE", "TH", "FR", "SA", "SU"].contains(String($0)) }) else { return false }
            } else if frequency == .monthly {
                guard monthDay == nil, dayRule.range(of: "^(-1|[1-4])(MO|TU|WE|TH|FR|SA|SU)$", options: .regularExpression) != nil else { return false }
            } else { return false }
        }
        return true
    }
    public func line(allDay: Bool, zone: TimeZone = .current) throws -> String {
        guard (1...999).contains(interval), count == nil || until == nil else { throw CalendarError.invalid("Choose one recurrence ending.") }
        let days = Set(["MO", "TU", "WE", "TH", "FR", "SA", "SU"])
        guard weekdays.allSatisfy({ days.contains($0) }), count.map({ (1...9999).contains($0) }) ?? true else { throw CalendarError.invalid("Invalid recurrence values.") }
        if ordinal != nil && weekdays.count != 1 { throw CalendarError.invalid("Choose the weekday for this monthly pattern.") }
        var fields = ["FREQ=\(frequency.rawValue)", "INTERVAL=\(interval)"]
        if let monthDay { guard (1...31).contains(monthDay) else { throw CalendarError.invalid("Invalid monthly date.") }; fields.append("BYMONTHDAY=\(monthDay)") }
        if !weekdays.isEmpty {
            if let ordinal { guard [-1, 1, 2, 3, 4, 5].contains(ordinal), weekdays.count == 1 else { throw CalendarError.invalid("Choose one ordinal weekday.") }; fields.append("BYDAY=\(ordinal)\(weekdays[0])") }
            else { fields.append("BYDAY=" + weekdays.joined(separator: ",")) }
        }
        if let count { fields.append("COUNT=\(count)") }
        if let until {
            if allDay { fields.append("UNTIL=" + until.description.replacingOccurrences(of: "-", with: "")) }
            else {
                let formatter = DateFormatter(); formatter.calendar = Calendar(identifier: .gregorian); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .gmt; formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
                fields.append("UNTIL=" + formatter.string(from: until.adding(days: 1).start(in: zone).addingTimeInterval(-1)))
            }
        }
        return "RRULE:" + fields.joined(separator: ";")
    }
}
