import SwiftUI
import CalendarCore

struct EventInspector: View {
    @Bindable var model: AppModel
    let event: CalendarEvent
    @State private var deleting = false
    @State private var scope = false
    @State private var response: String?
    private var removingOwnCopy: Bool { event.selfAttendee != nil && !event.organizerIsSelf }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack { Text(event.eventType == "default" ? "EVENT DETAILS" : event.eventType.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Button { model.selectedEvent = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain) }
                Text(event.title).font(.system(size: 23, weight: .semibold, design: .rounded)).textSelection(.enabled)
                Label(model.sourceLabel(event.key.calendar), systemImage: "calendar").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 5) {
                    if let time = event.time { Text(time.interval(in: model.preferences.timeZone).start.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: model.preferences.timeZone))).font(.subheadline) }
                    Text(model.timeLabel(event)).font(.headline)
                    Text("Shown in \(model.preferences.timeZone.identifier)").font(.caption).foregroundStyle(.secondary)
                    if case .timed(_, _, let startZone, let endZone) = event.time { Text(startZone == endZone ? "Event zone: \(startZone)" : "Event zones: \(startZone) → \(endZone)").font(.caption2).foregroundStyle(.secondary) }
                    if event.isRecurring { Label("Repeating event", systemImage: "repeat").font(.caption).foregroundStyle(.secondary) }
                }
                if let state = event.localState { Label(state.label, systemImage: "clock.arrow.circlepath").font(.caption).foregroundStyle(.orange) }
                if !event.location.isEmpty { Label(event.location, systemImage: "mappin.and.ellipse").font(.subheadline).textSelection(.enabled) }
                ForEach(RichTextSafety.meetingLinks(event), id: \.self) { url in Link(destination: url) { Label("Join · \(url.host ?? "Meeting")", systemImage: "video") }.buttonStyle(.borderedProminent) }
                if !RichTextSafety.meetingLinks(event).isEmpty { Text("Your browser may be signed into a different account.").font(.caption).foregroundStyle(.secondary) }
                if let code = event.raw["conferenceData"]?["createRequest"]["status"]["statusCode"].string, code != "success" { Text(code == "pending" ? "Google is creating the meeting link." : "The event is saved, but meeting-link creation failed. Edit the event to request a replacement.").font(.caption).foregroundStyle(.secondary) }
                if !event.plainDescription.isEmpty { Text(event.plainDescription).font(.subheadline).textSelection(.enabled) }
                if !event.attendees.isEmpty {
                    VStack(alignment: .leading, spacing: 8) { Text("Guests").font(.headline); ForEach(Array(event.attendees.enumerated()), id: \.offset) { _, a in HStack { Image(systemName: a.flag("self") ? "person.crop.circle.fill" : "person.crop.circle"); VStack(alignment: .leading) { Text(a.text("displayName", default: a.text("email"))).lineLimit(2); Text(a.text("responseStatus")).font(.caption2).foregroundStyle(.secondary) } }.font(.caption) } }
                }
                if model.capability(.rsvp, event: event).allowed {
                    VStack(alignment: .leading, spacing: 8) { Text("Your response · \(event.response)").font(.caption); HStack { ForEach(["accepted", "tentative", "declined"], id: \.self) { value in Button(value == "accepted" ? "Accept" : value == "tentative" ? "Maybe" : "Decline") { response = value } } } }
                }
                ForEach(Array((event.raw["attachments"]?.array ?? []).enumerated()), id: \.offset) { _, attachment in
                    if let value = attachment["fileUrl"].string, let url = RichTextSafety.webURL(value) { Link(attachment["title"].string ?? "Attachment", destination: url) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    if model.capability(.edit, event: event).allowed { Button("Edit Event…") { if event.isRecurring { scope = true } else { model.edit(event) } }.buttonStyle(.borderedProminent) }
                    else { Text(model.capability(.edit, event: event).reason).font(.caption).foregroundStyle(.secondary) }
                    if !event.redacted { Button("Duplicate to another calendar…") { model.duplicate(event) } }
                    Button("Open in Google Calendar") { model.openGoogle(event) }
                    if model.capability(.delete, event: event).allowed { Button(removingOwnCopy ? "Remove from this calendar…" : event.masterID == nil && !event.recurrence.isEmpty ? "Delete entire series…" : "Delete event…", role: .destructive) { deleting = true } }
                    if model.isDemo && model.capability(.edit, event: event).allowed { Button("Simulate conflicting edits") { model.simulateConflict(event) }.font(.caption).foregroundStyle(.secondary) }
                }.buttonStyle(.link)
            }.padding(24)
        }
        .confirmationDialog("Choose recurrence scope", isPresented: $scope, titleVisibility: .visible) {
            if event.masterID != nil { Button("This occurrence") { model.edit(event) } }
            Button("Entire series") { model.edit(event, series: true) }
            Button("This and following · Open Google") { model.openGoogle(event) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This and following is handled in Google Calendar. Dayfold does not split a series into multiple remote operations.") }
        .confirmationDialog(removingOwnCopy ? "Remove your copy of this meeting?" : "Delete \(event.title)?", isPresented: $deleting, titleVisibility: .visible) {
            Button(event.masterID != nil ? "Remove this occurrence" : event.isRecurring ? "Remove entire series" : "Remove event", role: .destructive) { model.removeEvent(event) }
            if event.masterID != nil { Button("Remove entire series", role: .destructive) { model.removeEvent(event, series: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Uses \(model.sourceLabel(event.key.calendar)). " + (removingOwnCopy ? "This removes the invited copy from this calendar. It does not cancel the organizer's meeting. Google may notify the organizer about your response." : event.hasGuests ? "Google will send cancellation updates to guests. Queued offline deletions send when synchronized." : "The deletion is saved locally before synchronization.")) }
        .confirmationDialog("Send your response?", isPresented: Binding(get: { response != nil }, set: { if !$0 { response = nil } }), titleVisibility: .visible) {
            Button("Respond for \(event.masterID == nil && event.isRecurring ? "entire series" : "this occurrence")") { if let response { model.rsvp(event, response: response) }; response = nil }
            if event.masterID != nil { Button("Respond for entire series") { if let response { model.rsvpSeries(event, response: response) }; response = nil } }
            Button("Cancel", role: .cancel) { response = nil }
        } message: { Text("Uses \(model.sourceLabel(event.key.calendar)). Only your invited attendee response changes.") }
    }
}
