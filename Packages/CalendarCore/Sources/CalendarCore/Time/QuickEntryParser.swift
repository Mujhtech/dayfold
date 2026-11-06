import Foundation

public struct QuickEntryPreview: Sendable {
    public var title: String
    public var time: EventTime?
    public var recurrence: [String]
    public var message: String?
}
public enum QuickEntryParser {
    public static func parse(_ input: String, now: Date, zone: TimeZone, duration: Int = 30, weekStart: Int = 2) -> QuickEntryPreview {
        var text = input, date = LocalDate(now, zone: zone), hour: Int?, minute = 0, minutes = duration, recurrence: [String] = []
        func take(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            let parts = (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
            if let range = Range(match.range, in: text) { text.removeSubrange(range) }; return parts
        }
        if input.range(of: "\\b\\d{1,2}/\\d{1,2}\\b", options: .regularExpression) != nil { return QuickEntryPreview(title: input, time: nil, recurrence: [], message: "Choose an explicit date and time in the editor.") }
        if let p = take("\\bfor\\s+(\\d+)\\s+(minutes?|hours?)\\b") {
            guard let n = Int(p[1]), (1...10080).contains(n) else { return QuickEntryPreview(title: input, time: nil, recurrence: [], message: "Choose a duration from one minute to seven days.") }
            minutes = n * (p[2].lowercased().hasPrefix("hour") ? 60 : 1)
        }
        if let p = take("\\bat\\s+(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)?\\b"), var h = Int(p[1]) {
            minute = Int(p[2]) ?? 0
            if !p[3].isEmpty { guard (1...12).contains(h) else { return QuickEntryPreview(title: input, time: nil, recurrence: [], message: "Enter a valid time.") }; h = h % 12 + (p[3].lowercased() == "pm" ? 12 : 0) }
            else if p[2].isEmpty && (1...12).contains(h) { return QuickEntryPreview(title: input, time: nil, recurrence: [], message: "Specify AM, PM, or a 24-hour time such as 14:00.") }
            hour = h
        }
        var explicitDate = false
        if take("\\btomorrow\\b") != nil { date = date.adding(days: 1); explicitDate = true }
        else if take("\\btoday\\b") != nil { explicitDate = true }
        else if let p = take("\\b(?:on\\s+)?(\\d{4}-\\d{2}-\\d{2})\\b") {
            guard let d = try? LocalDate(p[1]) else { return QuickEntryPreview(title: input, time: nil, recurrence: [], message: "That date does not exist.") }; date = d; explicitDate = true
        }
        if let p = take("\\b(every|next)?\\s*(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\\b") {
            let names = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
            let target = names.firstIndex(of: p[2].lowercased())! + 1
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone; calendar.firstWeekday = weekStart
            if p[1].lowercased() == "next" {
                let start = calendar.date(byAdding: .weekOfYear, value: 1, to: calendar.dateInterval(of: .weekOfYear, for: now)!.start)!
                date = LocalDate(calendar.date(byAdding: .day, value: (target - weekStart + 7) % 7, to: start)!, zone: zone)
            } else {
                var delta = (target - calendar.component(.weekday, from: now) + 7) % 7
                if delta == 0, let h = hour, let time = WallTime.candidates(day: date, hour: h, minute: minute, zone: zone).first, time <= now { delta = 7 }
                date = date.adding(days: delta)
            }
            if p[1].lowercased() == "every" { var r = RecurrenceRule(frequency: .weekly); r.weekdays = [["SU", "MO", "TU", "WE", "TH", "FR", "SA"][target - 1]]; recurrence = (try? [r.line(allDay: false, zone: zone)]) ?? [] }
            explicitDate = true
        }
        if let p = take("\\bevery\\s+(day|week|month|year)\\b") {
            let frequency: RecurrenceRule.Frequency = ["day": .daily, "week": .weekly, "month": .monthly, "year": .yearly][p[1].lowercased()]!
            recurrence = (try? [RecurrenceRule(frequency: frequency).line(allDay: false, zone: zone)]) ?? []
        }
        if hour == nil {
            let rounded = Date(timeIntervalSince1970: ceil(now.timeIntervalSince1970 / 900) * 900)
            var c = Calendar(identifier: .gregorian); c.timeZone = zone
            hour = explicitDate ? 9 : c.component(.hour, from: rounded); minute = explicitDate ? 0 : c.component(.minute, from: rounded)
            if !explicitDate { date = LocalDate(rounded, zone: zone) }
        }
        let candidates = WallTime.candidates(day: date, hour: hour!, minute: minute, zone: zone)
        guard candidates.count == 1, (1...10080).contains(minutes) else {
            return QuickEntryPreview(title: input, time: nil, recurrence: recurrence, message: candidates.count > 1 ? "This time occurs twice. Choose its offset in the editor." : "This time does not exist. Choose a valid time.")
        }
        let title = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return QuickEntryPreview(title: title, time: .timed(start: candidates[0], end: candidates[0].addingTimeInterval(Double(minutes) * 60), startZone: zone.identifier, endZone: zone.identifier), recurrence: recurrence, message: title.isEmpty ? "This will be saved as Untitled Event." : nil)
    }
}
