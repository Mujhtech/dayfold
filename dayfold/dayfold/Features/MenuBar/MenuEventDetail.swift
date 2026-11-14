import SwiftUI
import CalendarCore

struct MenuEventDetail: View {
    @Bindable var model: AppModel
    let event: CalendarEvent
    let openCalendar: () -> Void
    @State private var response: String?
    private var canEdit: Bool { model.capability(.edit, event: event).allowed }
    private var links: [URL] { RichTextSafety.meetingLinks(event) }
    private var sourceColor: Color { Color(calendarHex: model.calendars.first { $0.key == event.key.calendar }?.color ?? "#5578C5") }

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 8) {
                Text(event.title)
                    .font(.system(size: 17, weight: .semibold))
                    .tracking(-0.2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(alignment: .top, spacing: 6) {
                    Circle().fill(sourceColor).frame(width: 5, height: 5).padding(.top, 4)
                    Text(model.sourceLabel(event.key.calendar))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let state = event.localState {
                    Label(state.label, systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                metadata("calendar") {
                    VStack(alignment: .leading, spacing: 4) {
                        if let time = event.time {
                            Text(time.interval(in: model.preferences.timeZone).start.formatted(Date.FormatStyle(timeZone: model.preferences.timeZone).weekday(.wide).month(.abbreviated).day().year()))
                                .font(.system(size: 12, weight: .medium))
                        }
                        Text(model.timeLabel(event)).font(.system(size: 12)).monospacedDigit()
                        Text(model.preferences.timeZone.identifier.replacingOccurrences(of: "_", with: " "))
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                if event.isRecurring {
                    metadata("repeat") { Text("Repeating event").font(.system(size: 11)).foregroundStyle(.secondary) }
                }
                if !event.location.isEmpty {
                    metadata("mappin.and.ellipse") {
                        Text(event.location).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    }
                }
            }

            actions

            if !links.isEmpty {
                Text("Your browser may use a different Google account.")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let status = event.raw["conferenceData"]?["createRequest"]["status"]["statusCode"].string, status != "success" {
                Text(status == "pending" ? "The meeting link is being created." : "The event is saved. Open it in Calendar to review meeting-link creation.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }

            if model.capability(.rsvp, event: event).allowed {
                Divider()
                responseControls
            }

            if !event.plainDescription.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 7) {
                    Text("Notes").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Text(event.plainDescription)
                        .font(.system(size: 12)).lineSpacing(2)
                        .lineLimit(5)
                        .textSelection(.enabled)
                    Button("Read full details in Calendar", action: openCalendar)
                        .font(.system(size: 10)).foregroundStyle(.secondary).buttonStyle(DayfoldPressStyle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .confirmationDialog("Send your response?", isPresented: Binding(get: { response != nil }, set: { if !$0 { response = nil } }), titleVisibility: .visible) {
            Button(event.isRecurring ? (event.masterID == nil ? "Respond for entire series" : "Respond for this occurrence") : "Send response") {
                if let response { model.rsvp(event, response: response) }
                response = nil
            }
            if event.masterID != nil {
                Button("Respond for entire series") {
                    if let response { model.rsvpSeries(event, response: response) }
                    response = nil
                }
            }
            Button("Cancel", role: .cancel) { response = nil }
        } message: {
            Text("Uses \(model.sourceLabel(event.key.calendar)). Only the invited account's response changes.")
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if links.count == 1 {
                Link(destination: links[0]) {
                    Label("Join meeting", systemImage: "video").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if links.count > 1 {
                Menu {
                    ForEach(links, id: \.self) { url in
                        Link(url.host ?? "Meeting", destination: url)
                    }
                } label: {
                    Label("Join meeting", systemImage: "video").font(.system(size: 11, weight: .medium))
                }
                .controlSize(.small)
            }

            if canEdit {
                if event.isRecurring {
                    Menu {
                        if event.masterID != nil {
                            Button("Edit this occurrence…") { edit() }
                        }
                        Button("Edit entire series…") { edit(series: true) }
                        Button("This and following · Open Google") { model.openGoogle(event) }
                    } label: {
                        Label("Edit…", systemImage: "pencil").font(.system(size: 11))
                    }
                    .controlSize(.small)
                } else {
                    Button { edit() } label: {
                        Label("Edit…", systemImage: "pencil").font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("Open in Calendar", action: openCalendar)
                Button("Open in Google Calendar") { model.openGoogle(event) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary).frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Event actions")
            .accessibilityLabel("Event actions")
        }
    }

    private var responseControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Your response").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(responseTitle).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                ForEach(["accepted", "tentative", "declined"], id: \.self) { value in
                    Button { response = value } label: {
                        Text(value == "accepted" ? "Accept" : value == "tentative" ? "Maybe" : "Decline")
                            .font(.system(size: 11, weight: event.response == value ? .medium : .regular))
                            .foregroundStyle(event.response == value ? Color.dayfoldAccent : .primary)
                            .frame(maxWidth: .infinity, minHeight: 27)
                            .background(Color.primary.opacity(event.response == value ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(DayfoldPressStyle())
                    .accessibilityAddTraits(event.response == value ? [.isSelected] : [])
                }
            }
        }
    }

    private var responseTitle: String {
        switch event.response {
        case "accepted": "Accepted"
        case "tentative": "Tentative"
        case "declined": "Declined"
        case "needsAction": "Awaiting response"
        default: event.response
        }
    }

    private func edit(series: Bool = false) {
        model.edit(event, series: series)
        openCalendar()
    }

    private func metadata<Content: View>(_ symbol: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14, height: 16)
            content()
        }
    }
}
