import SwiftUI
import CalendarCore

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var detailKey: EventKey?
    private var detailEvent: CalendarEvent? { (model.companionEvents + model.menuEvents + model.events).first { $0.key == detailKey } }
    private var events: [CalendarEvent] { model.companionEvents.filter { event in
        guard let time = event.time, model.calendars.contains(where: { $0.key == event.key.calendar && $0.visible }), event.response != "declined" else { return false }
        return time.interval(in: model.preferences.timeZone).overlapsExclusive(model.calendar.dateInterval(of: .day, for: model.menuDate)!)
    } }
    var body: some View {
        Group {
        if let detailKey {
            VStack(alignment: .leading, spacing: 16) {
                Button("Back to agenda") { self.detailKey = nil }.buttonStyle(.link)
                if let event = detailEvent {
                    MenuEventDetail(model: model, event: event, openCalendar: { open(event) })
                } else { ContentUnavailableView("Event unavailable", systemImage: "calendar.badge.exclamationmark", description: Text("The event may have been removed or its calendar is no longer available.")); Button("Open Calendar") { model.route(to: detailKey, join: false) } }
            }.padding(20).frame(width: 350)
        } else {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Your day, at a glance").font(.headline); Spacer(); if model.isDemo { Text("DEMO").font(.caption2.bold()).foregroundStyle(.orange) } }
            HStack { Button { model.menuDate = model.calendar.date(byAdding: .day, value: -1, to: model.menuDate)! } label: { Image(systemName: "chevron.left") }; Spacer(); DatePicker("Date", selection: $model.menuDate, displayedComponents: .date).labelsHidden(); Spacer(); Button { model.menuDate = model.calendar.date(byAdding: .day, value: 1, to: model.menuDate)! } label: { Image(systemName: "chevron.right") } }.buttonStyle(.plain)
            if let next = model.nextEvent, model.calendar.isDateInToday(model.menuDate) {
                Button { detailKey = next.key } label: {
                    VStack(alignment: .leading, spacing: 7) { Text((next.time?.interval(in: model.preferences.timeZone).start ?? .distantFuture) <= model.now ? "NOW" : "UP NEXT").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary); Text(String(next.title.prefix(30))).font(.title3.bold()).lineLimit(2); Text(model.timeLabel(next)).font(.caption); Text(model.sourceLabel(next.key.calendar)).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }.buttonStyle(.plain).accessibilityLabel(model.accessibleEventLabel(next))
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if events.isEmpty { Text(model.companionCovered ? "No visible events in this downloaded day." : "Events for this day have not been downloaded.").font(.callout).foregroundStyle(.secondary).padding(24) }
                    ForEach(events) { event in
                        Button { detailKey = event.key } label: {
                            HStack(alignment: .top, spacing: 10) {
                                RoundedRectangle(cornerRadius: 2).fill(Color(calendarHex: model.calendars.first { $0.key == event.key.calendar }?.color ?? "#5578C5")).frame(width: 3, height: 36)
                                VStack(alignment: .leading, spacing: 4) { Text(String(event.title.prefix(30))).font(.system(size: 12, weight: .medium)).lineLimit(2); Text(model.timeLabel(event)).font(.caption2).foregroundStyle(.secondary); Text(model.sourceLabel(event.key.calendar)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
                                Spacer()
                                MeetingLinkControl(event: event)
                            }.padding(.vertical, 10).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(model.accessibleEventLabel(event))
                        Divider()
                    }
                }
            }.frame(maxHeight: 310)
            HStack { Button { if let open = model.openQuickEntry { open() } else { openWindow(id: "quick-entry") } } label: { Label("Quick Add", systemImage: "plus") }; Spacer(); Button("Open Calendar") { showCalendar() } }.controlSize(.small)
            Divider()
            HStack {
                Menu("Calendars") { Button("All") { model.setVisibilitySet("All") }; ForEach(model.preferences.savedSets.keys.sorted(), id: \.self) { name in Button(name) { model.setVisibilitySet(name) } } }
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }.help(model.statusMessage)
                Spacer(); SettingsLink { Image(systemName: "gearshape") }; Button("Quit") { NSApp.terminate(nil) }
            }.buttonStyle(.plain).font(.caption)
        }.padding(20).frame(width: 350)
        .onChange(of: model.menuDate) { Task { await model.loadCompanionDay(fetch: true) } }
        }
        }.environment(\.timeZone, model.preferences.timeZone)
    }
    private func showCalendar() { if let open = model.openCalendar { open() } else { openWindow(id: "calendar"); NSApp.activate(ignoringOtherApps: true) } }
    private func open(_ event: CalendarEvent) { model.selectedEvent = event; model.selectedDate = event.time?.interval(in: model.preferences.timeZone).start ?? Date(); model.dateChanged(); showCalendar() }
}

struct QuickEntryView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let preview = QuickEntryParser.parse(model.quickText, now: model.now, zone: model.preferences.timeZone, duration: model.preferences.defaultDuration, weekStart: model.calendar.firstWeekday)
        VStack(alignment: .leading, spacing: 18) {
            HStack { Label("Quick entry", systemImage: "sparkle").font(.headline); Spacer(); if model.isDemo { Text("DEMO").font(.caption).foregroundStyle(.orange) } }
            TextField("Lunch Friday at 1pm for 45 minutes", text: $model.quickText).textFieldStyle(.roundedBorder).controlSize(.large).onSubmit { model.quickPreview() }
            if !model.quickText.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(preview.title.isEmpty ? "Untitled Event" : preview.title).font(.title3.bold())
                    if let time = preview.time { let range = time.interval(in: model.preferences.timeZone); Text(range.start.formatted(Date.FormatStyle(date: .complete, time: .shortened, timeZone: model.preferences.timeZone))); Text("Through \(range.end.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: model.preferences.timeZone))) · \(model.preferences.timeZone.identifier)").font(.caption) }
                    if let message = preview.message { Text(message).font(.caption).foregroundStyle(.orange) }
                    if !preview.recurrence.isEmpty { Text(preview.recurrence.joined(separator: "\n")).font(.caption.monospaced()) }
                    if let key = model.preferences.defaultCalendar { Text(model.sourceLabel(key)).font(.caption).foregroundStyle(.secondary) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack { Text("Preview only. Review before saving.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Keep Draft & Close") { model.saveQuickText(); dismiss() }; Button(preview.time == nil ? "Choose date & time…" : "Review Event") { model.quickPreview(); dismiss() }.buttonStyle(.borderedProminent).disabled(model.quickText.isEmpty) }
        }.onChange(of: model.quickText) { model.saveQuickText() }.onExitCommand { model.saveQuickText(); dismiss() }
    }
}
extension AppModel {
    func saveQuickText() {
        let text = quickText, updated = Date(), repo = repository, destination = preferences.defaultCalendar
        Task { do { if text.isEmpty { try await repo?.discardDraft("quick-entry-text", at: updated) } else { try await repo?.saveDraft(EventDraft(id: "quick-entry-text", calendar: destination, fields: ["summary": .string(text), "quickInput": .string(text)], updated: updated)) } } catch { errorMessage = error.localizedDescription } }
    }
}
