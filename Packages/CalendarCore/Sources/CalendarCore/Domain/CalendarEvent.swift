import Foundation

public struct CalendarEvent: Codable, Equatable, Sendable, Identifiable {
    public var key: EventKey
    public var raw: JSONObject
    public var calendarZone: String
    public var localState: MutationState?
    public var id: String { key.id }
    public init(key: EventKey, raw: JSONObject, calendarZone: String = "UTC", localState: MutationState? = nil) {
        self.key = key; self.raw = raw; self.calendarZone = calendarZone; self.localState = localState
    }
    public var title: String { raw.text("summary").isEmpty ? "Untitled Event" : raw.text("summary") }
    public var location: String { raw.text("location") }
    public var descriptionText: String { raw.text("description") }
    public var etag: String? { raw["etag"]?.string }
    public var time: EventTime? { EventTime.decode(raw, calendarZone: calendarZone) }
    public var cancelled: Bool { raw.text("status") == "cancelled" }
    public var eventType: String { raw.text("eventType", default: "default") }
    public var masterID: String? { raw["recurringEventId"]?.string }
    public var originalStart: JSONValue? { raw["originalStartTime"] }
    public var recurrence: [String] { raw["recurrence"]?.array?.compactMap(\.string) ?? [] }
    public var isRecurring: Bool { masterID != nil || !recurrence.isEmpty }
    public var attendees: [JSONObject] { raw["attendees"]?.array?.compactMap(\.object) ?? [] }
    public var selfAttendee: JSONObject? { attendees.first { $0.flag("self") } }
    public var response: String { selfAttendee?.text("responseStatus", default: "needsAction") ?? "accepted" }
    public var tentative: Bool { response == "tentative" || raw.text("status") == "tentative" }
    public var organizerIsSelf: Bool { raw["organizer"]?["self"].bool == true }
    public var hasGuests: Bool { attendees.contains { !$0.flag("self") } }
    public var redacted: Bool { raw.flag("dayfoldRedacted") }
    public var isBusy: Bool { raw.text("transparency") != "transparent" && !cancelled && response != "declined" }
    public var plainDescription: String { RichTextSafety.plainText(descriptionText) }
    public func redactingDetails() -> Self {
        let allowed = Set(["id", "start", "end", "status", "recurringEventId", "originalStartTime", "etag", "eventType"])
        var v = self; v.raw = raw.filter { allowed.contains($0.key) }; v.raw["summary"] = .string("Busy"); v.raw["dayfoldRedacted"] = .bool(true); return v
    }
}

public enum EventAction: Sendable { case create, edit, delete, rsvp, seriesStructure }
public struct Capability: Sendable {
    public var allowed: Bool
    public var reason: String
    public static let yes = Self(allowed: true, reason: "")
    public static func no(_ reason: String) -> Self { Self(allowed: false, reason: reason) }
}

public enum EventCapabilityResolver {
    public static func resolve(_ action: EventAction, account: CalendarAccount?, calendar: CalendarSource?, event: CalendarEvent? = nil) -> Capability {
        guard let a = account, let c = calendar, c.key.account == a.id, !c.deleted else { return .no("This source is unavailable.") }
        if let event, event.key.calendar != c.key { return .no("This event belongs to a different account or calendar.") }
        guard a.scopes.contains(GoogleScope.events) else { return .no("Reconnect this account to allow event changes.") }
        guard ![.removing, .blockedByOrganization].contains(a.status) else { return .no("This account cannot make changes right now.") }
        if action == .create { return c.writable ? .yes : .no("Choose a writable calendar.") }
        guard let e = event, !e.cancelled, !e.redacted, e.eventType == "default", !e.raw.flag("locked") else { return .no("This event can be viewed here. Open Google Calendar for supported changes.") }
        if c.role == "writerWithoutPrivateAccess" && e.raw.text("visibility") == "private" { return .no("Private details are not accessible to this account.") }
        if action == .rsvp { return c.readable && e.selfAttendee != nil && !e.organizerIsSelf ? .yes : .no("Only the invited account can respond.") }
        guard c.writable else { return .no("This calendar allows viewing only.") }
        if e.selfAttendee != nil && !e.organizerIsSelf {
            if action == .delete { return .yes }
            if action == .edit && e.raw.flag("guestsCanModify") { return .yes }
            return .no("The organizer controls this meeting. You can respond to your invitation.")
        }
        return .yes
    }
}
