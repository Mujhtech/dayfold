import Foundation

/// The only event fields needed for a one-day planning conversation. Event bodies,
/// attendee lists, meeting links and provider JSON are deliberately not exposed.
public struct AssistantDayEvent: Equatable, Sendable {
    public let key: EventKey
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    public let isBusy: Bool
}

public struct AssistantCalendarCoverage: Equatable, Sendable {
    public let key: CalendarKey
    public let title: String
    public let isComplete: Bool
    /// Fresh according to this repository snapshot: matching generation/write
    /// epoch, no stale flag and no current source error. This is not a live-server
    /// guarantee; the app should refresh before offering availability.
    public let isFresh: Bool
}

/// A bounded civil-day view across all nondeleted calendars with synchronization
/// enabled, including calendars hidden in the UI. Disabled calendars are excluded
/// from this explicitly limited scope, never implicitly considered free.
public struct AssistantDayContext: Sendable {
    public let day: LocalDate
    public let timeZone: TimeZone
    public var timeZoneIdentifier: String { timeZone.identifier }
    public let interval: DateInterval
    public let calendars: [AssistantCalendarCoverage]
    public let events: [AssistantDayEvent]
    public let totalEventCount: Int
    public let eventsTruncated: Bool
    public let excludedCalendarCount: Int
    public let invalidEventCount: Int

    public var availabilityIsReliable: Bool {
        !calendars.isEmpty && !eventsTruncated && invalidEventCount == 0
            && calendars.allSatisfy { $0.isComplete && $0.isFresh }
    }

    public init(snapshot: RepositorySnapshot, day: LocalDate, timeZone: TimeZone, maximumEvents: Int = 200) throws {
        guard (1...500).contains(maximumEvents) else {
            throw CalendarError.invalid("Choose an assistant event limit from 1 to 500.")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let start = day.start(in: timeZone)
        guard LocalDate(start, zone: timeZone) == day,
              let interval = calendar.dateInterval(of: .day, for: start), interval.duration > 0 else {
            throw CalendarError.invalid("This date does not exist in the selected time zone.")
        }
        self.day = day
        self.timeZone = timeZone
        self.interval = interval

        let sources = snapshot.calendars.filter { !$0.deleted && $0.syncEnabled }.sorted { $0.id < $1.id }
        let keys = Set(sources.map(\.key))
        excludedCalendarCount = snapshot.calendars.filter { !$0.deleted && !$0.syncEnabled }.count
        calendars = sources.map { source in
            let accessible = source.readable || source.freeBusyOnly
            let windows = snapshot.coverage.filter { $0.calendar == source.key && $0.generation == source.generation }
            return AssistantCalendarCoverage(
                key: source.key,
                title: String(source.title.prefix(120)),
                isComplete: accessible && Self.covers(interval, with: windows.map(\.interval)),
                isFresh: accessible && source.lastError == nil && Self.covers(interval, with: windows.filter {
                    !$0.stale && $0.writeEpoch == source.writeEpoch
                }.map(\.interval))
            )
        }

        var invalid = 0
        let dayEvents = snapshot.events.compactMap { event -> AssistantDayEvent? in
            guard keys.contains(event.key.calendar), !event.cancelled else { return nil }
            guard let source = sources.first(where: { $0.key == event.key.calendar }), source.readable || source.freeBusyOnly else { return nil }
            guard let time = event.time else { invalid += 1; return nil }
            switch time {
            case .timed(let start, let end, _, _) where end < start:
                invalid += 1; return nil
            case .allDay(let start, let end) where end < start:
                invalid += 1; return nil
            default: break
            }
            let eventInterval = time.interval(in: timeZone)
            let overlaps = eventInterval.duration == 0
                ? interval.start <= eventInterval.start && eventInterval.start < interval.end
                : eventInterval.overlapsExclusive(interval)
            guard overlaps else { return nil }
            let restricted = event.redacted || source.freeBusyOnly
                || (source.role == "writerWithoutPrivateAccess" && event.raw.text("visibility") == "private")
            return AssistantDayEvent(
                key: event.key,
                title: restricted ? "Busy" : String(event.title.prefix(200)),
                start: eventInterval.start,
                end: eventInterval.end,
                isAllDay: time.isAllDay,
                isBusy: restricted || event.isBusy
            )
        }.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.key.id < $1.key.id
        }
        totalEventCount = dayEvents.count
        eventsTruncated = dayEvents.count > maximumEvents
        invalidEventCount = invalid
        events = Array(dayEvents.prefix(maximumEvents))
    }

    /// Adjacent downloaded windows jointly cover a day; any actual hole fails.
    private static func covers(_ target: DateInterval, with intervals: [DateInterval]) -> Bool {
        var reached = target.start
        for window in intervals.sorted(by: { $0.start < $1.start }) {
            guard window.end > reached else { continue }
            if window.start > reached { return false }
            reached = max(reached, window.end)
            if reached >= target.end { return true }
        }
        return false
    }
}
