import SwiftUI
import CalendarCore

private struct EditorValues: Codable, Equatable {
    var title = "", location = "", notes = "", guests = "", destination = "", zone = ""
    var endZone: String?
    var start = Date(), end = Date().addingTimeInterval(1800)
    var allDay = false
    var visibility = "default", transparency = "opaque", recurrence = "none"
    var interval = 1, monthDay = 1, ordinal = 1, count = 10
    var weekdays: Set<String> = []
    var monthlyMode = "day", recurrenceEnd = "never"
    var until = Date()
    var reminders = "default", reminderMinutes = 10
    var createMeet = false
    var startOffset = -1, endOffset = -1
    @MainActor init(draft: EventDraft, model: AppModel) {
        if let saved = draft.fields["dayfoldEditor"], let data = try? JSONEncoder().encode(saved), let decoded = try? JSONDecoder().decode(Self.self, from: data) { self = decoded; return }
        title = draft.fields.text("summary"); location = draft.fields.text("location"); notes = draft.fields.text("description")
        guests = (draft.fields["attendees"]?.array ?? []).compactMap { $0["email"].string }.joined(separator: ", ")
        destination = draft.calendar?.id ?? ""; zone = draft.fields["start"]?["timeZone"].string ?? model.preferences.timeZone.identifier
        endZone = draft.fields["end"]?["timeZone"].string ?? zone
        if let time = EventTime.decode(draft.fields, calendarZone: zone) {
            allDay = time.isAllDay
            let range = time.interval(in: TimeZone(identifier: zone) ?? .current); start = range.start
            if case .allDay(_, let last) = time { end = last.adding(days: -1).start(in: TimeZone(identifier: zone) ?? .current) } else { end = range.end }
        }
        visibility = draft.fields.text("visibility", default: "default"); transparency = draft.fields.text("transparency", default: "opaque")
        if draft.fields["recurrence"]?.array?.isEmpty == false { recurrence = "custom" }
        let reminder = draft.fields["reminders"]
        if reminder?["useDefault"].bool == false { reminders = reminder?["overrides"].array?.isEmpty == false ? "preserve" : "none" }
        until = model.calendar.date(byAdding: .month, value: 3, to: start)!
        monthDay = model.calendar.component(.day, from: start)
        let z = TimeZone(identifier: zone) ?? .current
        if let source = draft.source, source.time?.isAllDay == false {
            let startOptions = Self.options(start, zone: z), endOptions = Self.options(end, zone: TimeZone(identifier: endZone ?? zone) ?? z)
            startOffset = startOptions.firstIndex(of: start) ?? -1; endOffset = endOptions.firstIndex(of: end) ?? -1
        }
    }
    static func options(_ date: Date, zone: TimeZone) -> [Date] {
        var c = Calendar(identifier: .gregorian); c.timeZone = zone
        return WallTime.candidates(day: LocalDate(date, zone: zone), hour: c.component(.hour, from: date), minute: c.component(.minute, from: date), zone: zone)
    }
}

struct EventEditor: View {
    @Bindable var model: AppModel
    let draft: EventDraft
    @State private var values: EditorValues
    @State private var saving = false
    @State private var localStatus = "Draft saved on this Mac"
    @State private var error: String?
    @State private var confirmGuests = false
    @State private var confirmStructure = false
    @State private var showTimeZones: Bool
    @State private var showNotes: Bool
    @State private var showGuests: Bool
    @State private var showOptions: Bool
    @FocusState private var titleFocused: Bool

    init(model: AppModel, draft: EventDraft) {
        self.model = model; self.draft = draft
        let initial = EditorValues(draft: draft, model: model)
        _values = State(initialValue: initial)
        _showTimeZones = State(initialValue: (initial.endZone != nil && initial.endZone != initial.zone)
                              || TimeZone(identifier: initial.zone) == nil
                              || TimeZone(identifier: initial.endZone ?? initial.zone) == nil)
        _showNotes = State(initialValue: !initial.notes.isEmpty)
        _showGuests = State(initialValue: !initial.guests.isEmpty || draft.source?.raw.flag("attendeesOmitted") == true)
        _showOptions = State(initialValue: initial.visibility != "default" || initial.transparency != "opaque" || initial.reminders != "default")
    }

    private var zone: TimeZone { TimeZone(identifier: values.zone) ?? model.preferences.timeZone }
    private var endZone: TimeZone { TimeZone(identifier: values.endZone ?? values.zone) ?? zone }
    private var selectedCalendar: CalendarSource? { model.calendars.first { $0.id == values.destination } }
    private var guestsLocked: Bool { draft.source?.raw.flag("attendeesOmitted") == true || (draft.source?.selfAttendee != nil && draft.source?.organizerIsSelf == false) }
    private var guestCount: Int { values.guests.split(separator: ",").filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count }
    private var editorTitle: String {
        if draft.repairingMutationID != nil { return "Correct event" }
        if draft.source == nil { return "New event" }
        if draft.source?.masterID != nil { return "Edit this occurrence" }
        return draft.source?.recurrence.isEmpty == false ? "Edit entire series" : "Edit event"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    titleSection
                    Divider()
                    scheduleSection
                    Divider()
                    detailSection
                    Divider()
                    optionalDetails
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(saving)
            if let error {
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text(error).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 11)).foregroundStyle(.red)
                .padding(.horizontal, 24).padding(.vertical, 10)
                .background(Color.red.opacity(0.04))
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 600)
        .onAppear { titleFocused = true }
        .onChange(of: values) { persist(close: false) }
        .onExitCommand { if !saving { persist(close: true) } }
        .confirmationDialog("Send updates to guests?", isPresented: $confirmGuests, titleVisibility: .visible) { Button("Save and send Google updates") { submit() }; Button("Cancel", role: .cancel) {} } message: { Text("\(sourceDescription). This change may send invitations or updates. Offline changes send when they synchronize.\(draft.source?.isRecurring == true ? " The editor title shows the recurrence scope." : "")") }
        .confirmationDialog("Change the entire series?", isPresented: $confirmStructure, titleVisibility: .visible) { Button("Review online and save series") { submit() }; Button("Cancel", role: .cancel) {} } message: { Text("The original series start and all future occurrences are affected. Existing exceptions remain with Google. \(sourceDescription)") }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: draft.source == nil ? "calendar.badge.plus" : "pencil")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Text(editorTitle).font(.system(size: 13, weight: .semibold))
            Spacer()
            Button { persist(close: true) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 24, height: 24)
                    .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain).disabled(saving)
            .help("Close and keep draft").accessibilityLabel("Close and keep draft")
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
    }

    private var titleSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Add a title", text: $values.title)
                .font(.system(size: 25, weight: .semibold)).tracking(-0.5)
                .textFieldStyle(.plain)
                .focused($titleFocused)
                .accessibilityLabel("Event title").accessibilityIdentifier("event-title")
            HStack(spacing: 8) {
                Circle().fill(Color(calendarHex: selectedCalendar?.color ?? "#5578C5"))
                    .frame(width: 7, height: 7)
                if draft.source != nil || draft.repairingMutationID != nil {
                    Text(sourceDescription)
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Picker("Calendar", selection: $values.destination) {
                        Text("Choose a calendar").tag("")
                        ForEach(model.calendars.filter(\.writable)) { source in
                            Text(model.sourceLabel(source.key)).tag(source.id)
                        }
                    }
                    .labelsHidden().controlSize(.small)
                    .frame(maxWidth: 360, alignment: .leading)
                }
                Spacer(minLength: 0)
            }
            if draft.repairingMutationID != nil {
                editorNote("Correcting the rejected change. Saving keeps the original event identity.")
            }
            if values.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                editorNote("Leave the title blank to use “Untitled Event”.")
            }
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                sectionTitle("Schedule")
                Spacer()
                Text(durationLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                Toggle("All day", isOn: $values.allDay)
                    .toggleStyle(.switch).controlSize(.mini).font(.system(size: 11))
                    .fixedSize().padding(.leading, 12)
            }
            if let message = draft.fields["dayfoldParsingMessage"]?.string {
                Label(message, systemImage: "info.circle")
                    .font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            editorRow("Starts") {
                dateFields("Start", selection: $values.start, in: zone)
            }
            editorRow(values.allDay ? "Last day" : "Ends") {
                dateFields("End", selection: $values.end, in: values.allDay ? zone : endZone)
            }
            if values.allDay {
                editorRow("") { editorNote("Includes the start and last day.") }
            } else {
                DisclosureGroup(isExpanded: $showTimeZones) {
                    VStack(alignment: .leading, spacing: 10) {
                        editorRow("Starts in") {
                            TextField("e.g. Africa/Lagos", text: $values.zone)
                                .textFieldStyle(.roundedBorder).accessibilityLabel("Start time zone")
                        }
                        editorRow("Ends in") {
                            TextField("e.g. Africa/Lagos", text: Binding(get: { values.endZone ?? values.zone }, set: { values.endZone = $0 }))
                                .textFieldStyle(.roundedBorder).accessibilityLabel("End time zone")
                        }
                        editorRow("") { editorNote("Use time-zone names such as Africa/Lagos or Europe/London.") }
                    }.padding(.top, 10)
                } label: {
                    HStack(spacing: 8) {
                        Text("Time zones").font(.system(size: 11))
                        Text(timeZoneSummary).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.leading, 88)
                offsetChoice("Start offset", date: values.start, zone: zone, selection: $values.startOffset)
                offsetChoice("End offset", date: values.end, zone: endZone, selection: $values.endOffset)
            }
            if draft.source?.masterID == nil {
                editorRow("Repeat") {
                    Picker("Repeats", selection: $values.recurrence) {
                        Text("Does not repeat").tag("none")
                        Text("Daily").tag("DAILY"); Text("Weekly").tag("WEEKLY")
                        Text("Monthly").tag("MONTHLY"); Text("Yearly").tag("YEARLY")
                        if draft.fields["recurrence"] != nil { Text("Keep existing recurrence").tag("custom") }
                    }.labelsHidden().frame(maxWidth: 270, alignment: .leading)
                }
                if values.recurrence != "none" && values.recurrence != "custom" { recurrenceControls }
                if values.recurrence == "custom" {
                    editorRow("") {
                        VStack(alignment: .leading, spacing: 5) {
                            editorNote("The existing repeat schedule will be preserved.")
                            DisclosureGroup("View repeat rule") {
                                Text((draft.fields["recurrence"]?.array ?? []).compactMap(\.string).joined(separator: "\n"))
                                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    .padding(.top, 4)
                            }.font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                editorNote("Only this occurrence changes. The series keeps its original schedule.")
            }
        }.controlSize(.small)
    }

    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Location & meeting")
            editorRow("Location") {
                TextField("Add a place or meeting link", text: $values.location)
                    .textFieldStyle(.roundedBorder).accessibilityLabel("Location or meeting URL")
            }
            if selectedCalendar?.allowsMeet == true {
                editorRow("Video call") {
                    VStack(alignment: .leading, spacing: 6) {
                        Toggle(draft.fields["conferenceData"] == nil ? "Add Google Meet" : "Replace Google Meet link", isOn: $values.createMeet)
                            .font(.system(size: 12))
                        if values.createMeet {
                            editorNote(model.isDemo ? "Demo keeps the request; it won’t create a real meeting link." : "Your link appears after Google confirms it.")
                        } else if draft.fields["conferenceData"] != nil {
                            editorNote("The current meeting link will be kept.")
                        }
                    }
                }
            }
        }.controlSize(.small)
    }

    private var optionalDetails: some View {
        VStack(alignment: .leading, spacing: 16) {
            DisclosureGroup(isExpanded: $showGuests) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("name@example.com, another@example.com", text: $values.guests, axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Guests, comma-separated emails")
                        .disabled(guestsLocked)
                    if guestsLocked {
                        editorNote(draft.source?.raw.flag("attendeesOmitted") == true ? "Google hasn’t returned the full guest list, so guests can’t be changed here." : "Only the organizer can change this event’s guests.")
                    } else {
                        editorNote("Separate guest email addresses with commas.")
                    }
                    if !values.guests.isEmpty {
                        editorNote("Saving sends Google updates to guests. Offline changes send when they reconnect.")
                    }
                }.padding(.top, 10)
            } label: {
                disclosureTitle("Guests", symbol: "person.2", summary: guestCount == 0 ? "Add people" : "\(guestCount) \(guestCount == 1 ? "guest" : "guests")")
            }
            Divider()
            DisclosureGroup(isExpanded: $showNotes) {
                TextField("Add notes, an agenda, or a link…", text: $values.notes, axis: .vertical)
                    .font(.system(size: 12)).lineLimit(4...12).textFieldStyle(.plain)
                    .padding(10)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .accessibilityLabel("Description").padding(.top, 10)
            } label: {
                disclosureTitle("Notes", symbol: "text.alignleft", summary: values.notes.isEmpty ? "Add a description" : values.notes)
            }
            Divider()
            DisclosureGroup(isExpanded: $showOptions) {
                optionControls.padding(.top, 12)
            } label: {
                disclosureTitle("Options", symbol: "slider.horizontal.3", summary: optionsSummary)
            }
        }.controlSize(.small)
    }

    private var optionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            editorRow("Show as") {
                Picker("Availability", selection: $values.transparency) {
                    Text("Busy").tag("opaque"); Text("Free").tag("transparent")
                }.labelsHidden().frame(width: 170)
            }
            editorRow("Visibility") {
                Picker("Visibility", selection: $values.visibility) {
                    Text("Calendar default").tag("default"); Text("Private").tag("private"); Text("Public").tag("public")
                }.labelsHidden().frame(maxWidth: 270, alignment: .leading)
            }
            editorRow("Reminder") {
                Picker("Reminder", selection: $values.reminders) {
                    Text("Calendar defaults").tag("default"); Text("None").tag("none"); Text("Custom popup").tag("custom")
                    if draft.source != nil { Text("Keep existing reminders").tag("preserve") }
                }.labelsHidden().frame(maxWidth: 270, alignment: .leading)
            }
            if values.reminders == "custom" {
                editorRow("") {
                    Stepper("\(values.reminderMinutes) minutes before", value: $values.reminderMinutes, in: 0...40320, step: 5)
                        .frame(maxWidth: 270, alignment: .leading)
                }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle").font(.system(size: 10))
                Text(localStatus).font(.system(size: 10))
                Spacer()
                if model.isDemo { Text("Demo · Local only").font(.system(size: 10)) }
            }.foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(role: .destructive) {
                    Task { do { try await model.discardDraft(draft.id); model.editingDraft = nil } catch { self.error = error.localizedDescription } }
                } label: {
                    Label("Discard Draft", systemImage: "trash").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(saving)
                Spacer()
                Button("Save Draft") { persist(close: false) }.keyboardShortcut("s").disabled(saving)
                Button(saving ? "Saving…" : draft.source == nil ? "Create Event" : "Save Changes") {
                    if !values.guests.isEmpty || draft.source?.hasGuests == true { confirmGuests = true }
                    else if draft.source?.recurrence.isEmpty == false && structureChanged { confirmStructure = true }
                    else { submit() }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(saving || values.destination.isEmpty).accessibilityIdentifier("save-event")
            }.controlSize(.regular)
        }.padding(.horizontal, 24).padding(.vertical, 12)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func editorNote(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func editorRow<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
                .frame(width: 74, alignment: .trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func dateFields(_ label: String, selection: Binding<Date>, in timeZone: TimeZone) -> some View {
        HStack(spacing: 10) {
            DatePicker("\(label) date", selection: selection, displayedComponents: .date)
                .labelsHidden().datePickerStyle(.field).fixedSize()
            if !values.allDay {
                DatePicker("\(label) time", selection: selection, displayedComponents: .hourAndMinute)
                    .labelsHidden().datePickerStyle(.field).fixedSize()
            }
            Spacer(minLength: 0)
        }.environment(\.timeZone, timeZone)
    }

    private func disclosureTitle(_ title: String, symbol: String, summary: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer(minLength: 16)
            Text(summary.replacingOccurrences(of: "\n", with: " "))
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var durationLabel: String {
        if values.allDay {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: values.start), to: calendar.startOfDay(for: values.end)).day ?? 0) + 1
            return days > 0 ? (days == 1 ? "1 day" : "\(days) days") : "Check end date"
        }
        let minutes = Int(values.end.timeIntervalSince(values.start) / 60)
        if minutes <= 0 { return "Check end time" }
        let hours = minutes / 60, remainder = minutes % 60
        return hours == 0 ? "\(minutes) min" : remainder == 0 ? "\(hours) hr" : "\(hours) hr \(remainder) min"
    }

    private var timeZoneSummary: String {
        if values.zone != (values.endZone ?? values.zone) { return "\(zone.abbreviation(for: values.start) ?? values.zone) → \(endZone.abbreviation(for: values.end) ?? values.endZone ?? values.zone)" }
        let city = values.zone.components(separatedBy: "/").last?.replacingOccurrences(of: "_", with: " ") ?? values.zone
        return "\(city) · \(zone.abbreviation(for: values.start) ?? values.zone)"
    }

    private var optionsSummary: String {
        let availability = values.transparency == "transparent" ? "Free" : "Busy"
        let reminder = values.reminders == "none" ? "No reminder" : values.reminders == "custom" ? "\(values.reminderMinutes) min reminder" : values.reminders == "preserve" ? "Existing reminders" : "Default reminder"
        return availability + (values.visibility == "default" ? "" : " · " + values.visibility.capitalized) + " · " + reminder
    }
    private var sourceDescription: String { model.calendars.first(where: { $0.id == values.destination }).map { model.sourceLabel($0.key) } ?? "Choose a calendar" }
    private var structureChanged: Bool { let original = EditorValues(draft: draft, model: model); return values.start != original.start || values.end != original.end || values.zone != original.zone || values.endZone != original.endZone || values.allDay != original.allDay || values.recurrence != original.recurrence }
    @ViewBuilder private func offsetChoice(_ label: String, date: Date, zone: TimeZone, selection: Binding<Int>) -> some View {
        let options = EditorValues.options(date, zone: zone)
        if options.count > 1 {
            editorRow(label) {
                VStack(alignment: .leading, spacing: 5) {
                    Picker(label, selection: selection) {
                        Text("Choose an offset").tag(-1)
                        ForEach(options.indices, id: \.self) { i in
                            Text("\(zone.abbreviation(for: options[i]) ?? zone.identifier) · UTC\(zone.secondsFromGMT(for: options[i]) / 3600 >= 0 ? "+" : "")\(Double(zone.secondsFromGMT(for: options[i])) / 3600)").tag(i)
                        }
                    }.labelsHidden()
                    editorNote("This time occurs twice. Choose which one to use.")
                }
            }
        }
    }
    private var recurrenceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            editorRow("Every") {
                Stepper("\(values.interval) \(recurrenceUnit)", value: $values.interval, in: 1...99)
                    .frame(maxWidth: 270, alignment: .leading)
            }
            if values.recurrence == "MONTHLY" {
                editorRow("Pattern") {
                    Picker("Monthly pattern", selection: $values.monthlyMode) {
                        Text("Day of month").tag("day"); Text("Ordinal weekday").tag("weekday")
                    }.labelsHidden().frame(maxWidth: 270, alignment: .leading)
                }
                editorRow(values.monthlyMode == "day" ? "On day" : "On the") {
                    if values.monthlyMode == "day" {
                        Stepper("\(values.monthDay)", value: $values.monthDay, in: 1...31).frame(maxWidth: 270, alignment: .leading)
                    } else {
                        Picker("Occurrence", selection: $values.ordinal) {
                            Text("First").tag(1); Text("Second").tag(2); Text("Third").tag(3); Text("Fourth").tag(4); Text("Last").tag(-1)
                        }.labelsHidden().frame(maxWidth: 270, alignment: .leading)
                    }
                }
            }
            if values.recurrence == "WEEKLY" || (values.recurrence == "MONTHLY" && values.monthlyMode == "weekday") {
                editorRow("On") {
                    HStack(spacing: 4) {
                        ForEach(["MO", "TU", "WE", "TH", "FR", "SA", "SU"], id: \.self) { day in
                            Toggle(weekdayLabel(day), isOn: Binding(get: { values.weekdays.contains(day) }, set: {
                                if $0 {
                                    if values.recurrence == "MONTHLY" { values.weekdays = [day] }
                                    else { values.weekdays.insert(day) }
                                } else { values.weekdays.remove(day) }
                            }))
                            .toggleStyle(.button).font(.system(size: 10)).help(weekdayLabel(day))
                        }
                    }
                }
            }
            editorRow("Ends") {
                Picker("Repeat ends", selection: $values.recurrenceEnd) {
                    Text("Never").tag("never"); Text("On a date").tag("date"); Text("After a count").tag("count")
                }.labelsHidden().frame(maxWidth: 270, alignment: .leading)
            }
            if values.recurrenceEnd == "date" {
                editorRow("Through") {
                    DatePicker("Repeat through", selection: $values.until, displayedComponents: .date)
                        .labelsHidden().datePickerStyle(.field).environment(\.timeZone, zone).fixedSize()
                }
            }
            if values.recurrenceEnd == "count" {
                editorRow("") {
                    Stepper("\(values.count) occurrences", value: $values.count, in: 1...9999)
                        .frame(maxWidth: 270, alignment: .leading)
                }
            }
            editorRow("") { editorNote("Google expands repeating events. Offline display covers downloaded dates only.") }
        }
    }

    private var recurrenceUnit: String {
        let unit = ["DAILY": "day", "WEEKLY": "week", "MONTHLY": "month", "YEARLY": "year"][values.recurrence] ?? "day"
        return unit + (values.interval == 1 ? "" : "s")
    }

    private func weekdayLabel(_ code: String) -> String {
        ["MO": "Mon", "TU": "Tue", "WE": "Wed", "TH": "Thu", "FR": "Fri", "SA": "Sat", "SU": "Sun"][code] ?? code
    }
    private func assembled(validate: Bool) throws -> EventDraft {
        var result = draft; result.updated = Date(); result.calendar = model.calendars.first { $0.id == values.destination }?.key
        result.fields["dayfoldEditor"] = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(values))
        let originalValues = EditorValues(draft: draft, model: model)
        if draft.source == nil || values.title != originalValues.title { result.fields["summary"] = .string(values.title) }
        if draft.source == nil || values.location != originalValues.location { result.fields["location"] = .string(values.location) }
        if draft.source == nil || values.notes != originalValues.notes { result.fields["description"] = .string(values.notes) }
        if validate && (TimeZone(identifier: values.zone) == nil || TimeZone(identifier: values.endZone ?? values.zone) == nil) { throw CalendarError.invalid("Enter a recognized IANA time zone, such as Africa/Lagos.") }
        let time: EventTime
        if values.allDay { time = .allDay(start: LocalDate(values.start, zone: zone), end: LocalDate(values.end, zone: zone).adding(days: 1)) }
        else {
            let starts = EditorValues.options(values.start, zone: zone), ends = EditorValues.options(values.end, zone: endZone)
            if validate && ((starts.count > 1 && values.startOffset < 0) || (ends.count > 1 && values.endOffset < 0)) { throw CalendarError.invalid("Choose the UTC offset for each repeated time.") }
            time = .timed(start: starts.indices.contains(values.startOffset) ? starts[values.startOffset] : values.start, end: ends.indices.contains(values.endOffset) ? ends[values.endOffset] : values.end, startZone: zone.identifier, endZone: endZone.identifier)
        }
        if draft.source == nil || values.start != originalValues.start || values.end != originalValues.end || values.zone != originalValues.zone || values.endZone != originalValues.endZone || values.allDay != originalValues.allDay || values.startOffset != originalValues.startOffset || values.endOffset != originalValues.endOffset {
            result.fields.merge(time.providerFields) { _, v in v }
        }
        if draft.source?.masterID == nil && values.recurrence != "custom" {
            if let frequency = RecurrenceRule.Frequency(rawValue: values.recurrence) {
                var rule = RecurrenceRule(frequency: frequency); rule.interval = values.interval; rule.weekdays = values.weekdays.sorted()
                if frequency == .monthly { if values.monthlyMode == "day" { rule.monthDay = values.monthDay } else { rule.ordinal = values.ordinal } }
                if values.recurrenceEnd == "count" { rule.count = values.count }; if values.recurrenceEnd == "date" { rule.until = LocalDate(values.until, zone: zone) }
                if validate { result.fields["recurrence"] = .array([.string(try rule.line(allDay: values.allDay, zone: zone))]) }
                else if let line = try? rule.line(allDay: values.allDay, zone: zone) { result.fields["recurrence"] = .array([.string(line)]) }
            } else if draft.source?.recurrence.isEmpty == false { result.fields["recurrence"] = .array([]) } else { result.fields["recurrence"] = nil }
        }
        let original = EditorValues(draft: draft, model: model)
        if values.guests != original.guests {
            let emails = values.guests.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if validate && emails.contains(where: { $0.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) == nil }) { throw CalendarError.invalid("Enter explicit guest email addresses separated by commas.") }
            let old = draft.source?.attendees ?? []
            result.fields["attendees"] = .array(emails.map { email in .object(old.first { $0.text("email").caseInsensitiveCompare(email) == .orderedSame } ?? ["email": .string(email)]) })
        } else if draft.source == nil && !values.guests.isEmpty { result.fields["attendees"] = .array(values.guests.split(separator: ",").map { .object(["email": .string($0.trimmingCharacters(in: .whitespacesAndNewlines))]) }) }
        if draft.source == nil || values.visibility != originalValues.visibility { result.fields["visibility"] = .string(values.visibility) }
        if draft.source == nil || values.transparency != originalValues.transparency { result.fields["transparency"] = .string(values.transparency) }
        if values.reminders != "preserve" && (draft.source == nil || values.reminders != originalValues.reminders || values.reminderMinutes != originalValues.reminderMinutes) { result.fields["reminders"] = .object(values.reminders == "default" ? ["useDefault": .bool(true)] : ["useDefault": .bool(false), "overrides": .array(values.reminders == "none" ? [] : [.object(["method": .string("popup"), "minutes": .number(Double(values.reminderMinutes))])])]) }
        if values.createMeet { result.fields["conferenceData"] = .object(["createRequest": .object(["requestId": .string(draft.id), "conferenceSolutionKey": .object(["type": .string("hangoutsMeet")])])]) }
        return result
    }
    private func persist(close: Bool) {
        do {
            let value = try assembled(validate: false)
            model.retainDraftForSave(value)
            Task { do { try await model.persistDraft(value); localStatus = "Draft saved on this Mac"; if close { model.editingDraft = nil } } catch { self.error = "Could not save locally. Your editor text is still here. " + error.localizedDescription } }
        } catch { self.error = error.localizedDescription }
    }
    private func submit() {
        do {
            let value = try assembled(validate: true); saving = true
            Task { defer { saving = false }; do { try await model.submit(value) } catch { self.error = error.localizedDescription } }
        } catch { self.error = error.localizedDescription }
    }
}
