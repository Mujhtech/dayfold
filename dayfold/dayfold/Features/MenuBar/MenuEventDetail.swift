import SwiftUI
import CalendarCore

struct MenuEventDetail: View {
    @Bindable var model: AppModel
    let event: CalendarEvent
    let openCalendar: () -> Void
    @State private var response: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(event.title).font(.title3.bold()).lineLimit(3)
            Text(model.timeLabel(event)).font(.subheadline)
            Text(model.sourceLabel(event.key.calendar)).font(.caption).foregroundStyle(.secondary)
            if let state = event.localState { Text(state.label).font(.caption).foregroundStyle(.orange) }
            if !event.location.isEmpty { Label(event.location, systemImage: "mappin").font(.caption).lineLimit(2) }
            MeetingLinkControl(event: event)
            if model.capability(.rsvp, event: event).allowed {
                HStack {
                    Button("Accept") { response = "accepted" }; Button("Maybe") { response = "tentative" }; Button("Decline") { response = "declined" }
                }.controlSize(.small)
            }
            if model.capability(.edit, event: event).allowed {
                Button(event.isRecurring ? "Edit this occurrence…" : "Edit Event…") { model.edit(event); openCalendar() }
            }
            Button("Open in Calendar", action: openCalendar)
            Button("Open in Google Calendar") { model.openGoogle(event) }.buttonStyle(.link)
        }
        .confirmationDialog("Send your response?", isPresented: Binding(get: { response != nil }, set: { if !$0 { response = nil } }), titleVisibility: .visible) {
            Button(event.isRecurring ? "Respond for this occurrence" : "Send response") { if let response { model.rsvp(event, response: response) }; response = nil }
            if event.masterID != nil { Button("Respond for entire series") { if let response { model.rsvpSeries(event, response: response) }; response = nil } }
        } message: { Text("Uses \(model.sourceLabel(event.key.calendar)). Only the invited account's response changes.") }
    }
}
