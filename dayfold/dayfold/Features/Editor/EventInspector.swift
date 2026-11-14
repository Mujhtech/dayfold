import SwiftUI
import CalendarCore

struct EventInspector: View {
    @Bindable var model: AppModel
    let event: CalendarEvent
    @State private var deleting = false
    @State private var scope = false
    @State private var response: String?
    private var removingOwnCopy: Bool { event.selfAttendee != nil && !event.organizerIsSelf }
    private var sourceColor: Color {
        Color(calendarHex: model.calendars.first { $0.key == event.key.calendar }?.color ?? "#5578C5")
    }
    private var meetingLinks: [URL] { RichTextSafety.meetingLinks(event) }
    private var canEdit: Bool { model.capability(.edit, event: event).allowed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(event.eventType == "default" ? "Event details" : event.eventType)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.selectedEvent = nil } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary).frame(width: 24, height: 24)
                            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain).help("Close event details").accessibilityLabel("Close event details")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text(event.title).font(.system(size: 22, weight: .semibold)).tracking(-0.5)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    HStack(spacing: 6) {
                        Circle().fill(sourceColor).frame(width: 6, height: 6)
                        Text(model.sourceLabel(event.key.calendar)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let state = event.localState {
                        Label(state.label, systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                    }
                }

                primaryActions
                Divider()
                eventMetadata

                if !event.plainDescription.isEmpty {
                    sectionHeading("Notes")
                    Text(event.plainDescription).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
                }
                if !event.attendees.isEmpty {
                    Divider()
                    guestList
                }
                if model.capability(.rsvp, event: event).allowed { responseControls }
                if !(event.raw["attachments"]?.array ?? []).isEmpty { attachments }

                Divider()
                secondaryActions
            }.padding(.horizontal, 20).padding(.vertical, 16)
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

    private var primaryActions: some View {
        VStack(alignment: .leading, spacing: 8) {
            if canEdit {
                Button {
                    if event.isRecurring { scope = true } else { model.edit(event) }
                } label: {
                    Label("Edit Event…", systemImage: "pencil").frame(maxWidth: .infinity)
                }.buttonStyle(.borderedProminent).tint(.dayfoldAccent).controlSize(.regular)
            } else {
                Text(model.capability(.edit, event: event).reason)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(meetingLinks, id: \.self) { url in
                Link(destination: url) {
                    HStack(spacing: 7) {
                        Image(systemName: "video")
                        Text(meetingLinks.count == 1 ? "Join meeting" : "Join · \(url.host ?? "Meeting")").lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
                    }.frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).controlSize(.regular)
            }
            if !meetingLinks.isEmpty {
                Text("Your browser may be signed into a different account.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let code = event.raw["conferenceData"]?["createRequest"]["status"]["statusCode"].string, code != "success" {
                Text(code == "pending" ? "Google is creating the meeting link." : "The event is saved, but meeting-link creation failed. Edit the event to request a replacement.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private var eventMetadata: some View {
        VStack(alignment: .leading, spacing: 16) {
            detailRow("calendar") {
                VStack(alignment: .leading, spacing: 4) {
                    if let time = event.time {
                        Text(time.interval(in: model.preferences.timeZone).start.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: model.preferences.timeZone)))
                            .font(.system(size: 12, weight: .medium))
                    }
                    Text(model.timeLabel(event)).font(.system(size: 12)).monospacedDigit()
                    Text("Shown in \(model.preferences.timeZone.identifier)")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if case .timed(_, _, let startZone, let endZone) = event.time {
                        Text(startZone == endZone ? "Event zone: \(startZone)" : "Event zones: \(startZone) → \(endZone)")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            if event.isRecurring {
                detailRow("repeat") { Text("Repeating event").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            if !event.location.isEmpty {
                detailRow("mappin.and.ellipse") {
                    Text(event.location).font(.system(size: 12)).textSelection(.enabled)
                }
            }
        }
    }

    private var guestList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionHeading("Guests")
                Spacer()
                Text("\(event.attendees.count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
            }
            ForEach(Array(event.attendees.enumerated()), id: \.offset) { _, attendee in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: attendee.flag("self") ? "person.crop.circle.fill" : "person.crop.circle")
                        .font(.system(size: 22, weight: .light)).foregroundStyle(.tertiary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(attendee.text("displayName", default: attendee.text("email")))
                            .font(.system(size: 12, weight: .medium)).lineLimit(2)
                        Text(responseTitle(attendee.text("responseStatus")))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var responseControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionHeading("Your response")
                Spacer()
                Text(responseTitle(event.response)).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(["accepted", "tentative", "declined"], id: \.self) { value in
                    Button { response = value } label: {
                        Text(value == "accepted" ? "Accept" : value == "tentative" ? "Maybe" : "Decline")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
    }

    private var attachments: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeading("Attachments")
            ForEach(Array((event.raw["attachments"]?.array ?? []).enumerated()), id: \.offset) { _, attachment in
                if let value = attachment["fileUrl"].string, let url = RichTextSafety.webURL(value) {
                    Link(destination: url) {
                        Label(attachment["title"].string ?? "Attachment", systemImage: "paperclip")
                            .font(.system(size: 12)).lineLimit(2)
                    }
                }
            }
        }
    }

    private var secondaryActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !event.redacted {
                Button { model.duplicate(event) } label: {
                    Label("Duplicate to another calendar…", systemImage: "plus.square.on.square")
                }
            }
            Button { model.openGoogle(event) } label: {
                Label("Open in Google Calendar", systemImage: "arrow.up.right.square")
            }
            if model.capability(.delete, event: event).allowed {
                Button(role: .destructive) { deleting = true } label: {
                    Label(removingOwnCopy ? "Remove from this calendar…" : event.masterID == nil && !event.recurrence.isEmpty ? "Delete entire series…" : "Delete event…", systemImage: "trash")
                }.foregroundStyle(.red)
            }
            if model.isDemo && canEdit {
                Button("Simulate conflicting edits") { model.simulateConflict(event) }
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }.font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func detailRow<Content: View>(_ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16, height: 17)
            content()
        }
    }

    private func responseTitle(_ value: String) -> String {
        switch value {
        case "accepted": "Accepted"
        case "tentative": "Tentative"
        case "declined": "Declined"
        case "needsAction": "Awaiting response"
        default: value
        }
    }

}
