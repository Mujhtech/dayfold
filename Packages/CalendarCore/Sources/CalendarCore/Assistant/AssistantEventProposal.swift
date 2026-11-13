import Foundation

/// Untrusted model output for one new timed event. The destination calendar is
/// chosen by the app/user, never by generated provider IDs or instructions.
public struct AssistantEventProposal: Codable, Equatable, Sendable {
    public var title: String
    public var date: String
    public var time: String
    public var durationMinutes: Int

    public init(title: String, date: String, time: String, durationMinutes: Int) {
        self.title = title
        self.date = date
        self.time = time
        self.durationMinutes = durationMinutes
    }

    public func validatedTime(in zone: TimeZone) throws -> EventTime {
        _ = try validatedTitle()
        guard (15...240).contains(durationMinutes) else {
            throw CalendarError.invalid("Choose a duration from 15 to 240 minutes.")
        }
        guard date.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil else {
            throw CalendarError.invalid("Use an exact YYYY-MM-DD date for the proposed event.")
        }
        let day = try LocalDate(date)
        guard day.year >= 1, day.description == date else {
            throw CalendarError.invalid("Choose a valid date for the proposed event.")
        }
        guard time.range(of: #"^[0-9]{2}:[0-9]{2}$"#, options: .regularExpression) != nil else {
            throw CalendarError.invalid("Use an exact 24-hour HH:mm time for the proposed event.")
        }
        let pieces = time.split(separator: ":")
        guard let hour = Int(pieces[0]), let minute = Int(pieces[1]), (0..<24).contains(hour), (0..<60).contains(minute) else {
            throw CalendarError.invalid("Choose a valid time for the proposed event.")
        }
        let candidates = WallTime.candidates(day: day, hour: hour, minute: minute, zone: zone)
        guard candidates.count == 1, let start = candidates.first else {
            throw CalendarError.invalid(candidates.isEmpty
                ? "That time does not exist in this time zone. Choose another time."
                : "That time occurs twice in this time zone. Choose an unambiguous time in the event editor.")
        }
        return .timed(start: start, end: start.addingTimeInterval(Double(durationMinutes) * 60), startZone: zone.identifier, endZone: zone.identifier)
    }

    /// Creates only a local draft. It neither queues nor sends a provider write.
    public func draft(calendar: CalendarKey, timeZone: TimeZone) throws -> EventDraft {
        var fields = try validatedTime(in: timeZone).providerFields
        fields["summary"] = .string(try validatedTitle())
        fields["reminders"] = .object(["useDefault": .bool(true)])
        return EventDraft(calendar: calendar, fields: fields)
    }

    private func validatedTitle() throws -> String {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 200,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CalendarError.invalid("Use an event title from 1 to 200 characters on one line.")
        }
        return value
    }
}
