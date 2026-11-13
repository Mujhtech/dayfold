import Foundation

public enum AssistantAvailability {
    /// Returns maximal free intervals long enough for the requested duration, in
    /// the context's explicit day and synchronized-calendar scope. Busy intervals
    /// are clipped and merged before gaps are computed. Results do not authorize a
    /// calendar write; an event proposal must still be reviewed.
    public static func freeSlots(
        in context: AssistantDayContext,
        durationMinutes: Int,
        workStart: Int,
        workEnd: Int,
        notBefore: Date? = nil
    ) throws -> [DateInterval] {
        guard (15...240).contains(durationMinutes) else {
            throw CalendarError.invalid("Choose a duration from 15 to 240 minutes.")
        }
        guard (0...24).contains(workStart), (0...24).contains(workEnd), workStart < workEnd else {
            throw CalendarError.invalid("Choose work hours from 0 to 24, with the end after the start.")
        }
        guard context.availabilityIsReliable else {
            throw CalendarError.unavailable("Refresh all synchronized calendars for this day before checking free time. Missing, stale or incomplete events cannot be treated as free time.")
        }
        let start = max(try boundary(workStart, in: context, end: false), notBefore ?? context.interval.start)
        let end = try boundary(workEnd, in: context, end: true)
        guard start < end else { return [] }
        let workday = DateInterval(start: start, end: end)
        let busy = context.events.filter(\.isBusy).compactMap { event -> DateInterval? in
            let start = max(workday.start, event.start), end = min(workday.end, event.end)
            return start < end ? DateInterval(start: start, end: end) : nil
        }.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }

        var merged: [DateInterval] = []
        for interval in busy {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else { merged.append(interval) }
        }

        let minimum = Double(durationMinutes) * 60
        var cursor = workday.start, slots: [DateInterval] = []
        for interval in merged {
            if interval.start.timeIntervalSince(cursor) >= minimum {
                slots.append(DateInterval(start: cursor, end: interval.start))
            }
            cursor = max(cursor, interval.end)
        }
        if workday.end.timeIntervalSince(cursor) >= minimum {
            slots.append(DateInterval(start: cursor, end: workday.end))
        }
        return slots
    }

    private static func boundary(_ hour: Int, in context: AssistantDayContext, end: Bool) throws -> Date {
        if hour == 0 { return context.interval.start }
        if hour == 24 { return context.interval.end }
        let candidates = WallTime.candidates(day: context.day, hour: hour, minute: 0, zone: context.timeZone)
        // During a repeated hour, use the widest actual working interval. If a
        // custom boundary falls in a skipped hour, ask for a valid boundary.
        guard let instant = end ? candidates.last : candidates.first else {
            throw CalendarError.invalid("A workday boundary falls in a daylight-saving gap. Choose another work hour for this day.")
        }
        return instant
    }
}
