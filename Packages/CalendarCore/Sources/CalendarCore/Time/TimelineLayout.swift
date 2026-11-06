import Foundation

public struct TimelinePlacement: Sendable, Identifiable {
    public var id: String { event.id }
    public var event: CalendarEvent
    public var start: Date
    public var end: Date
    public var column: Int
    public var columns: Int
    public var groupID: String
}
public enum TimelineLayout {
    public static func place(_ events: [CalendarEvent], day: DateInterval, zone: TimeZone) -> [TimelinePlacement] {
        let sorted = events.filter { event in
            guard let time = event.time, !time.isAllDay else { return false }
            let range = time.interval(in: zone)
            return range.duration == 0 ? day.start <= range.start && range.start < day.end : range.overlapsExclusive(day)
        }.sorted {
            let a = $0.time!.interval(in: zone), b = $1.time!.interval(in: zone)
            if a.start == b.start { return a.end == b.end ? $0.id < $1.id : a.end > b.end }; return a.start < b.start
        }
        var result: [TimelinePlacement] = [], group: [TimelinePlacement] = [], ends: [Date] = [], groupEnd = Date.distantPast
        func flush() {
            let count = ends.count
            let groupID = group.first?.id ?? ""
            result += group.map { var p = $0; p.columns = count; p.groupID = groupID; return p }; group = []; ends = []
        }
        for event in sorted {
            let range = event.time!.interval(in: zone)
            if range.start >= groupEnd && !group.isEmpty { flush() }
            let index = ends.firstIndex { $0 <= range.start } ?? ends.count
            if index == ends.count { ends.append(range.end) } else { ends[index] = range.end }
            group.append(TimelinePlacement(event: event, start: max(day.start, range.start), end: min(day.end, range.end), column: index, columns: 1, groupID: ""))
            groupEnd = max(groupEnd, range.end)
        }
        flush(); return result
    }
}

public struct TimelineOverflow: Sendable, Identifiable {
    public var id: String
    public var start: Date
    public var count: Int
}
public enum TimelineDensity {
    public static func overflow(_ placements: [TimelinePlacement], maximumColumns: Int) -> [TimelineOverflow] {
        Dictionary(grouping: placements, by: \.groupID).compactMap { id, group in
            guard (group.first?.columns ?? 0) > maximumColumns else { return nil }
            let hidden = group.filter { $0.column >= max(0, maximumColumns - 1) }
            guard let start = hidden.map(\.start).min() else { return nil }
            return TimelineOverflow(id: id, start: start, count: hidden.count)
        }.sorted { $0.start == $1.start ? $0.id < $1.id : $0.start < $1.start }
    }
}
