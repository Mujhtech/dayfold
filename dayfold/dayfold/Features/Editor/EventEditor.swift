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
    init(model: AppModel, draft: EventDraft) { self.model = model; self.draft = draft; _values = State(initialValue: EditorValues(draft: draft, model: model)) }
    private var zone: TimeZone { TimeZone(identifier: values.zone) ?? model.preferences.timeZone }
    private var endZone: TimeZone { TimeZone(identifier: values.endZone ?? values.zone) ?? zone }
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading, spacing: 4) { Text(draft.source == nil ? "New event" : draft.source?.masterID != nil ? "Edit this occurrence" : draft.source?.recurrence.isEmpty == false ? "Edit entire series" : "Edit event").font(.title2.bold()); Text(localStatus).font(.caption).foregroundStyle(.secondary) }; Spacer(); Button { persist(close: true) } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Close and keep draft") }.padding(22)
            Divider()
            Form {
                Section {
                    TextField("Event title", text: $values.title).font(.title3).accessibilityIdentifier("event-title")
                    if values.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text("Preview: Untitled Event").font(.caption).foregroundStyle(.secondary) }
                    Picker("Account / Calendar", selection: $values.destination) {
                        Text("Choose a calendar").tag("")
                        ForEach(model.calendars.filter(\.writable)) { source in Text(model.sourceLabel(source.key)).tag(source.id) }
                    }.disabled(draft.source != nil || draft.repairingMutationID != nil)
                    if draft.repairingMutationID != nil { Text("Correcting the rejected change. Saving reuses the original event identity.").font(.caption).foregroundStyle(.secondary) }
                    if let source = draft.source { Text("Changes use \(model.sourceLabel(source.key.calendar)).").font(.caption).foregroundStyle(.secondary) }
                }
                Section("Date & time") {
                    if let message = draft.fields["dayfoldParsingMessage"]?.string { Text(message).font(.caption).foregroundStyle(.orange) }
                    Toggle("All day", isOn: $values.allDay)
                    DatePicker("Starts", selection: $values.start, displayedComponents: values.allDay ? [.date] : [.date, .hourAndMinute]).environment(\.timeZone, zone)
                    DatePicker(values.allDay ? "Last day (inclusive)" : "Ends", selection: $values.end, displayedComponents: values.allDay ? [.date] : [.date, .hourAndMinute]).environment(\.timeZone, values.allDay ? zone : endZone)
                    if !values.allDay {
                        TextField("Time zone (IANA)", text: $values.zone)
                        TextField("End time zone (IANA)", text: Binding(get: { values.endZone ?? values.zone }, set: { values.endZone = $0 }))
                        offsetChoice("Start offset", date: values.start, zone: zone, selection: $values.startOffset)
                        offsetChoice("End offset", date: values.end, zone: endZone, selection: $values.endOffset)
                    }
                    if draft.source?.masterID == nil {
                        Picker("Repeats", selection: $values.recurrence) {
                            Text("Does not repeat").tag("none"); Text("Daily").tag("DAILY"); Text("Weekly").tag("WEEKLY"); Text("Monthly").tag("MONTHLY"); Text("Yearly").tag("YEARLY")
                            if draft.fields["recurrence"] != nil { Text("Custom recurrence · preserved").tag("custom") }
                        }
                        if values.recurrence != "none" && values.recurrence != "custom" { recurrenceControls }
                        if values.recurrence == "custom" { Text((draft.fields["recurrence"]?.array ?? []).compactMap(\.string).joined(separator: "\n")).font(.caption.monospaced()).textSelection(.enabled) }
                    } else { Text("Only this occurrence changes. The series keeps its original schedule.").font(.caption).foregroundStyle(.secondary) }
                }
                Section("Details") {
                    TextField("Location or meeting URL", text: $values.location)
                    TextField("Description", text: $values.notes, axis: .vertical).lineLimit(3...8)
                    TextField("Guests (comma-separated emails)", text: $values.guests).disabled(draft.source?.raw.flag("attendeesOmitted") == true || (draft.source?.selfAttendee != nil && draft.source?.organizerIsSelf == false))
                    if !values.guests.isEmpty { Text("Saving will send Google updates to guests, including when a queued change reconnects.").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Picker("Availability", selection: $values.transparency) { Text("Busy").tag("opaque"); Text("Free").tag("transparent") }
                        Picker("Visibility", selection: $values.visibility) { Text("Calendar default").tag("default"); Text("Private").tag("private"); Text("Public").tag("public") }
                    }
                    Picker("Reminder", selection: $values.reminders) { Text("Calendar defaults").tag("default"); Text("None").tag("none"); Text("Custom popup").tag("custom"); if draft.source != nil { Text("Keep existing reminders").tag("preserve") } }
                    if values.reminders == "custom" { Stepper("\(values.reminderMinutes) minutes before", value: $values.reminderMinutes, in: 0...40320, step: 5) }
                    if model.calendars.first(where: { $0.id == values.destination })?.allowsMeet == true {
                        Toggle(draft.fields["conferenceData"] == nil ? "Request a Google Meet link" : "Request a replacement Google Meet link", isOn: $values.createMeet)
                        if values.createMeet { Text(model.isDemo ? "Demo stores the request only; it does not create a real Meet link." : "The link appears after Google confirms creation.").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal, 22).padding(.bottom, 10) }
            Divider()
            HStack {
                Button("Discard Draft", role: .destructive) { Task { do { try await model.discardDraft(draft.id); model.editingDraft = nil } catch { self.error = error.localizedDescription } } }
                Spacer()
                Button("Save Draft") { persist(close: false) }.keyboardShortcut("s")
                Button(saving ? "Saving…" : "Save Event") {
                    if !values.guests.isEmpty || draft.source?.hasGuests == true { confirmGuests = true }
                    else if draft.source?.recurrence.isEmpty == false && structureChanged { confirmStructure = true }
                    else { submit() }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(saving || values.destination.isEmpty).accessibilityIdentifier("save-event")
            }.padding(18)
        }.frame(width: 620, height: 760)
        .onChange(of: values) { persist(close: false) }
        .confirmationDialog("Send updates to guests?", isPresented: $confirmGuests, titleVisibility: .visible) { Button("Save and send Google updates") { submit() }; Button("Cancel", role: .cancel) {} } message: { Text("\(sourceDescription). This change may send invitations or updates. Offline changes send when they synchronize.\(draft.source?.isRecurring == true ? " The editor title shows the recurrence scope." : "")") }
        .confirmationDialog("Change the entire series?", isPresented: $confirmStructure, titleVisibility: .visible) { Button("Review online and save series") { submit() }; Button("Cancel", role: .cancel) {} } message: { Text("The original series start and all future occurrences are affected. Existing exceptions remain with Google. \(sourceDescription)") }
    }
    private var sourceDescription: String { model.calendars.first(where: { $0.id == values.destination }).map { model.sourceLabel($0.key) } ?? "Choose a calendar" }
    private var structureChanged: Bool { let original = EditorValues(draft: draft, model: model); return values.start != original.start || values.end != original.end || values.zone != original.zone || values.endZone != original.endZone || values.allDay != original.allDay || values.recurrence != original.recurrence }
    @ViewBuilder private func offsetChoice(_ label: String, date: Date, zone: TimeZone, selection: Binding<Int>) -> some View {
        let options = EditorValues.options(date, zone: zone)
        if options.count > 1 {
            Picker(label, selection: selection) { Text("Choose an offset for this repeated time").tag(-1); ForEach(options.indices, id: \.self) { i in Text("\(zone.abbreviation(for: options[i]) ?? zone.identifier) · UTC\(zone.secondsFromGMT(for: options[i]) / 3600 >= 0 ? "+" : "")\(Double(zone.secondsFromGMT(for: options[i])) / 3600)").tag(i) } }
        }
    }
    private var recurrenceControls: some View {
        Group {
            Stepper("Every \(values.interval)", value: $values.interval, in: 1...99)
            if values.recurrence == "WEEKLY" || (values.recurrence == "MONTHLY" && values.monthlyMode == "weekday") {
                HStack { ForEach(["MO", "TU", "WE", "TH", "FR", "SA", "SU"], id: \.self) { day in Toggle(day, isOn: Binding(get: { values.weekdays.contains(day) }, set: { if $0 { if values.recurrence == "MONTHLY" { values.weekdays = [day] } else { values.weekdays.insert(day) } } else { values.weekdays.remove(day) } })).toggleStyle(.button) } }
            }
            if values.recurrence == "MONTHLY" {
                Picker("Monthly pattern", selection: $values.monthlyMode) { Text("Day of month").tag("day"); Text("Ordinal weekday").tag("weekday") }
                if values.monthlyMode == "day" { Stepper("Day \(values.monthDay)", value: $values.monthDay, in: 1...31) }
                else { Picker("Occurrence", selection: $values.ordinal) { Text("First").tag(1); Text("Second").tag(2); Text("Third").tag(3); Text("Fourth").tag(4); Text("Last").tag(-1) } }
            }
            Picker("Ends", selection: $values.recurrenceEnd) { Text("Never").tag("never"); Text("On date").tag("date"); Text("After count").tag("count") }
            if values.recurrenceEnd == "date" { DatePicker("Through", selection: $values.until, displayedComponents: .date) }
            if values.recurrenceEnd == "count" { Stepper("\(values.count) occurrences", value: $values.count, in: 1...9999) }
            Text("Google expands repeating events. Offline display covers downloaded dates only.").font(.caption).foregroundStyle(.secondary)
        }
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
