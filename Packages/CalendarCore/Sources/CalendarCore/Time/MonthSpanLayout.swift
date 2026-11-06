import Foundation

public struct MonthSpan: Identifiable, Sendable {
    public var id: String { event.id + ":\(week)" }
    public var event: CalendarEvent
    public var week: Int
    public var column: Int
    public var length: Int
    public var row: Int
}
public enum MonthSpanLayout {
    public static func spans(events: [CalendarEvent], gridStart: Date, calendar: Calendar, weeks: Int = 6) -> [MonthSpan] {
        let candidates = events.filter { event in
            guard let time = event.time else { return false }
            let interval = time.interval(in: calendar.timeZone)
            return time.isAllDay || !calendar.isDate(interval.start, inSameDayAs: interval.end.addingTimeInterval(-0.001))
        }.sorted { a, b in
            let ar = a.time!.interval(in: calendar.timeZone), br = b.time!.interval(in: calendar.timeZone)
            if ar.start == br.start { return ar.end == br.end ? a.id < b.id : ar.end > br.end }; return ar.start < br.start
        }
        var result: [MonthSpan] = [], preferred: [String: Int] = [:]
        for week in 0..<weeks {
            let first = calendar.date(byAdding: .day, value: week * 7, to: gridStart)!, end = calendar.date(byAdding: .day, value: 7, to: first)!
            var occupied: [Set<Int>] = []
            for event in candidates {
                let interval = event.time!.interval(in: calendar.timeZone)
                guard interval.overlapsExclusive(DateInterval(start: first, end: end)) else { continue }
                let startDay = calendar.startOfDay(for: max(first, interval.start))
                let endDay = calendar.startOfDay(for: min(end, interval.end).addingTimeInterval(-0.001))
                let column = calendar.dateComponents([.day], from: first, to: startDay).day ?? 0
                let length = (calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0) + 1
                let columns = Set(column..<(column + length))
                var row = preferred[event.id] ?? 0
                while occupied.count <= row { occupied.append([]) }
                if !occupied[row].isDisjoint(with: columns) {
                    row = occupied.firstIndex { $0.isDisjoint(with: columns) } ?? occupied.count
                    if row == occupied.count { occupied.append([]) }
                }
                occupied[row].formUnion(columns); preferred[event.id] = row
                result.append(MonthSpan(event: event, week: week, column: column, length: length, row: row))
            }
        }
        return result
    }
}
