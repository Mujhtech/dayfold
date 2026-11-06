import Foundation
import CryptoKit

public struct PlannedReminder: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var event: EventKey
    public var title: String
    public var source: String
    public var fire: Date
}
public enum ReminderPlanner {
    /// Capacity is Dayfold's request budget, not an assumed operating-system limit.
    public static func plan(events: [CalendarEvent], calendars: [CalendarSource], preferences: Preferences, now: Date, capacity: Int = 200, includeRecentPast: Bool = false) -> [PlannedReminder] {
        guard preferences.notifications else { return [] }
        let horizon = now.addingTimeInterval(14 * 86400)
        var planned: [PlannedReminder] = []
        for event in events where !event.cancelled && event.response != "declined" && !event.redacted {
            guard let source = calendars.first(where: { $0.key == event.key.calendar && $0.syncEnabled && !$0.deleted }), let time = event.time else { continue }
            let reminder = event.raw["reminders"] ?? .object(["useDefault": .bool(true)])
            let offsets = reminder["useDefault"].bool == true ? source.defaultReminderMinutes : (reminder["overrides"].array ?? []).filter { $0["method"].string == "popup" }.compactMap { $0["minutes"].number.map(Int.init) }
            for offset in Set(offsets) {
                let fire: Date
                switch time {
                case .timed(let start, _, _, _): fire = start.addingTimeInterval(Double(-offset) * 60)
                case .allDay(let day, _):
                    let zone = TimeZone(identifier: source.timeZone) ?? .gmt
                    guard let date = WallTime.candidates(day: day, hour: preferences.allDayHour, minute: 0, zone: zone).first else { continue }; fire = date.addingTimeInterval(Double(-offset) * 60)
                }
                guard fire > (includeRecentPast ? now.addingTimeInterval(-86400) : now), fire < horizon else { continue }
                let identity = event.id + ":\(offset):\(fire.timeIntervalSince1970)"
                let hash = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
                planned.append(PlannedReminder(id: "dayfold." + hash, event: event.key, title: preferences.privateNotifications ? "Busy event" : event.title, source: preferences.privateNotifications ? "Dayfold reminder" : source.title, fire: fire))
            }
        }
        return Array(planned.sorted { $0.fire < $1.fire }.prefix(capacity))
    }
}
