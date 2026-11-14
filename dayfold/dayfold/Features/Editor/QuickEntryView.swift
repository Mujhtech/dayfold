import SwiftUI
import CalendarCore

struct QuickEntryView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var inputFocused: Bool

    private var hasText: Bool { !model.quickText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var preview: QuickEntryPreview {
        QuickEntryParser.parse(model.quickText, now: model.now, zone: model.preferences.timeZone,
                               duration: model.preferences.defaultDuration, weekStart: model.calendar.firstWeekday)
    }
    private var calendarColor: Color {
        Color(calendarHex: model.calendars.first { $0.key == model.preferences.defaultCalendar }?.color ?? "#5578C5")
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Create an event")
                            .font(.system(size: 17, weight: .semibold))
                        Text("Type a plan. We’ll fill in the details.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.isDemo {
                        Text("Demo").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.045), in: Capsule())
                    }
                }
                TextField("Lunch Friday at 1pm for 45 minutes", text: $model.quickText, axis: .vertical)
                    .font(.system(size: 17)).textFieldStyle(.plain).lineLimit(2...3)
                    .focused($inputFocused).accessibilityLabel("Describe your event")
                    .padding(14)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(inputFocused ? Color.dayfoldAccent.opacity(0.65) : Color.primary.opacity(0.1), lineWidth: inputFocused ? 1 : 0.5))
                    .onSubmit { review() }
                Group {
                    if hasText { parsedPreview }
                    else { examples }
                }.frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
            }.padding(24)
            Divider()
            HStack(spacing: 10) {
                Text("Review before saving.").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("Keep Draft & Close") { close() }
                    .controlSize(.regular)
                Button(preview.time == nil && hasText ? "Choose Date & Time…" : "Review Event") { review() }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                    .keyboardShortcut(.defaultAction).disabled(!hasText)
            }.padding(.horizontal, 24).padding(.vertical, 14)
        }
        .onAppear { inputFocused = true }
        .onChange(of: model.quickText) { model.saveQuickText() }
        .onExitCommand { close() }
    }

    private var examples: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Try something like").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            ForEach(["Lunch tomorrow at 1pm for 45 minutes", "Focus every Monday at 9am for 1 hour"], id: \.self) { example in
                Button { model.quickText = example; inputFocused = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.up.left").font(.system(size: 9)).foregroundStyle(.tertiary)
                        Text(example).font(.system(size: 12)).foregroundStyle(.secondary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            Text("Use English dates and times, or YYYY-MM-DD for an exact date.")
                .font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 4)
        }
    }

    private var parsedPreview: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Preview").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if !preview.recurrence.isEmpty {
                    Label(recurrenceSummary, systemImage: "repeat").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                if let time = preview.time {
                    let start = time.interval(in: model.preferences.timeZone).start
                    VStack(spacing: 3) {
                        Text(start.formatted(Date.FormatStyle(timeZone: model.preferences.timeZone).month(.abbreviated)).uppercased())
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        Text(start.formatted(Date.FormatStyle(timeZone: model.preferences.timeZone).day()))
                            .font(.system(size: 24, weight: .medium)).monospacedDigit()
                    }
                    .frame(width: 54, height: 62)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: "calendar")
                        .font(.system(size: 23, weight: .light)).foregroundStyle(.secondary)
                        .frame(width: 54, height: 62)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(preview.title.isEmpty ? "Untitled Event" : preview.title)
                        .font(.system(size: 17, weight: .semibold)).lineLimit(2)
                    if let time = preview.time {
                        let range = time.interval(in: model.preferences.timeZone)
                        Text(range.start.formatted(Date.FormatStyle(timeZone: model.preferences.timeZone).weekday(.wide).month(.abbreviated).day()))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                        Text(timeSummary(time)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if let message = preview.message {
                        Text(message).font(.system(size: 11)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 6) {
                Circle().fill(calendarColor).frame(width: 6, height: 6)
                Text(model.preferences.defaultCalendar.map { model.sourceLabel($0) } ?? "Choose a calendar in the next step")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private func timeSummary(_ time: EventTime) -> String {
        if time.isAllDay { return "All day" }
        let zone = model.preferences.timeZone
        let range = time.interval(in: zone)
        let clock = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)
        let endStyle = model.calendar.isDate(range.start, inSameDayAs: range.end) ? clock : Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone)
        return "\(range.start.formatted(clock)) – \(range.end.formatted(endStyle)) · \(zone.abbreviation(for: range.start) ?? zone.identifier)"
    }

    private var recurrenceSummary: String {
        let rule = preview.recurrence.joined(separator: ";")
        let weekdays = ["MO": "Monday", "TU": "Tuesday", "WE": "Wednesday", "TH": "Thursday", "FR": "Friday", "SA": "Saturday", "SU": "Sunday"]
        if let day = rule.components(separatedBy: ";").first(where: { $0.hasPrefix("BYDAY=") })?.dropFirst(6),
           let name = weekdays[String(day)] { return "Every \(name)" }
        if rule.contains("FREQ=DAILY") { return "Daily" }
        if rule.contains("FREQ=WEEKLY") { return "Weekly" }
        if rule.contains("FREQ=MONTHLY") { return "Monthly" }
        if rule.contains("FREQ=YEARLY") { return "Yearly" }
        return "Repeating event"
    }

    private func review() {
        guard hasText else { return }
        model.quickPreview()
        dismiss()
    }

    private func close() {
        model.saveQuickText()
        dismiss()
    }
}
