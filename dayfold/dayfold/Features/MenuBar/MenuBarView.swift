import SwiftUI
import CalendarCore

struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dayfoldReduceMotion) private var reduceMotion
    @State private var detailKey: EventKey?
    @State private var choosingDate = false

    private var detailEvent: CalendarEvent? {
        (model.companionEvents + model.menuEvents + model.events).first { $0.key == detailKey }
    }
    private var selectedDay: DateInterval { model.calendar.dateInterval(of: .day, for: model.menuDate)! }
    private var isToday: Bool { model.calendar.isDateInToday(model.menuDate) }
    private var events: [CalendarEvent] {
        guard model.companionDayIsLoaded else { return [] }
        return model.companionEvents.filter { event in
            guard let time = event.time,
                  model.calendars.contains(where: { $0.key == event.key.calendar && $0.visible }),
                  event.response != "declined" else { return false }
            return time.interval(in: model.preferences.timeZone).overlapsExclusive(selectedDay)
        }
    }
    private var focusEvent: CalendarEvent? {
        guard isToday, let next = model.nextEvent, events.contains(where: { $0.key == next.key }) else { return nil }
        return next
    }
    private var agendaEvents: [CalendarEvent] { events.filter { $0.key != focusEvent?.key } }
    private var statusText: String {
        if model.companionDayError != nil { return model.isDemo ? "Demo · Could not load day" : "Could not load day" }
        if !model.companionDayIsLoaded { return model.isDemo ? "Demo · Loading day…" : "Loading day…" }
        if model.isDemo { return model.demoOffline ? "Demo · Offline" : "Demo · Local only" }
        if !model.companionCovered { return "This day is not downloaded" }
        if model.accounts.contains(where: { $0.status != .healthy }) { return "Cached · " + model.statusMessage }
        return model.statusMessage
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .frame(height: 64)
            Divider()
            ZStack(alignment: .topLeading) {
                if let detailKey {
                    detail(key: detailKey)
                        .id(detailKey)
                        .transition(pageTransition(from: .trailing))
                } else {
                    agenda
                        .transition(pageTransition(from: .leading))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            Divider()
            footer
        }
        .frame(width: 360, height: 530)
        .environment(\.timeZone, model.preferences.timeZone)
        .onChange(of: model.menuDate) { Task { await model.loadCompanionDay(fetch: true) } }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if detailKey != nil {
                Button { dismissDetail() } label: {
                    Label("Agenda", systemImage: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(DayfoldPressStyle())
                Spacer()
                Text("Event details").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Button { choosingDate.toggle() } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Text(isToday ? "Today" : model.menuDate.formatted(Date.FormatStyle(timeZone: model.preferences.timeZone).weekday(.wide)))
                                .font(.system(size: 14, weight: .semibold))
                                .contentTransition(.opacity)
                                .animation(DayfoldMotion.quick(reduceMotion), value: model.menuDate)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium)).foregroundStyle(.secondary)
                        }
                        Text(headerDate)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .contentTransition(.opacity)
                            .animation(DayfoldMotion.quick(reduceMotion), value: model.menuDate)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(DayfoldPressStyle())
                .help("Choose a date")
                .popover(isPresented: $choosingDate) {
                    DatePicker("Go to date", selection: $model.menuDate, displayedComponents: .date)
                        .padding(16)
                }
                Spacer(minLength: 8)
                if !isToday {
                    Button("Today") { model.menuDate = model.now }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .buttonStyle(DayfoldPressStyle())
                        .padding(.trailing, 2)
                }
                HStack(spacing: 2) {
                    dayButton(-1)
                    dayButton(1)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var agenda: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let event = focusEvent {
                    CompanionFocusEvent(model: model, event: event) { showDetail(event) }
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Schedule")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        if model.companionDayIsLoaded {
                            Text("\(events.count) \(events.count == 1 ? "event" : "events")")
                                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 2)
                    if let error = model.companionDayError {
                        unavailableAgenda(error)
                    } else if !model.companionDayIsLoaded {
                        loadingAgenda
                    } else if agendaEvents.isEmpty {
                        emptyAgenda
                    } else {
                        LazyVStack(spacing: 1) {
                            ForEach(agendaEvents) { event in
                                CompanionAgendaRow(model: model, event: event) { showDetail(event) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .id(selectedDay.start)
            .transition(.opacity)
        }
        .scrollIndicators(.never)
        .animation(DayfoldMotion.standard(reduceMotion), value: selectedDay.start)
    }

    private var loadingAgenda: some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text("Loading your day…").font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.vertical, 16)
    }

    private func unavailableAgenda(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This day couldn’t be loaded.").font(.system(size: 12, weight: .medium))
            Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { Task { await model.loadCompanionDay(fetch: true) } }
                .font(.system(size: 11)).buttonStyle(.bordered).controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.vertical, 16)
    }

    private var emptyAgenda: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(focusEvent != nil ? "No other events today." : model.companionCovered ? "Nothing scheduled." : "No cached events for this day.")
                .font(.system(size: 12, weight: .medium))
            Text(model.companionCovered ? "Choose another day to see what's ahead." : "Open Calendar or refresh when you're online.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .padding(.vertical, 16)
    }

    @ViewBuilder private func detail(key: EventKey) -> some View {
        if let event = detailEvent {
            ScrollView {
                MenuEventDetail(model: model, event: event, openCalendar: { open(event) })
                    .padding(18)
            }
            .scrollIndicators(.never)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
                Text("Event unavailable").font(.system(size: 14, weight: .semibold))
                Text("It may have been removed, or its calendar is no longer available.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Open in Calendar") { model.route(to: key, join: false) }
                    .font(.system(size: 11)).buttonStyle(.bordered).controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private var footer: some View {
        VStack(spacing: 9) {
            HStack(spacing: 7) {
                Text(statusText)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(model.isDemo ? "Fictional events, stored only on this Mac." : model.statusMessage)
                Spacer(minLength: 6)
                Menu {
                    Menu("Calendars") {
                        Button("All calendars") { model.setVisibilitySet("All") }
                        ForEach(model.preferences.savedSets.keys.sorted(), id: \.self) { name in
                            Button(name) { model.setVisibilitySet(name) }
                        }
                    }
                    Button("Refresh calendars", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                        .disabled(model.isRefreshing)
                    SettingsLink { Label("Settings…", systemImage: "gearshape") }
                    Divider()
                    Button("Quit Dayfold") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary).frame(width: 20, height: 18).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More actions")
                .accessibilityLabel("More actions")
            }
            HStack(spacing: 8) {
                Button {
                    if let open = model.openQuickEntry { open() }
                    else { openWindow(id: "quick-entry") }
                } label: {
                    Label("Quick Add", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .foregroundStyle(.primary)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(DayfoldPressStyle())
                Button {
                    if let event = detailEvent { open(event) }
                    else if let key = detailKey { model.route(to: key, join: false) }
                    else { showCalendar() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Open Calendar")
                        Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .medium))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 30)
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(DayfoldPressStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 13)
    }

    private func dayButton(_ direction: Int) -> some View {
        Button {
            model.menuDate = model.calendar.date(byAdding: .day, value: direction, to: model.menuDate)!
        } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 25, height: 27)
                .contentShape(Rectangle())
        }
        .buttonStyle(DayfoldPressStyle())
        .help(direction < 0 ? "Previous day" : "Next day")
        .accessibilityLabel(direction < 0 ? "Previous day" : "Next day")
    }

    private func pageTransition(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .offset(x: edge == .leading ? -20 : 20).combined(with: .opacity)
    }
    private var headerDate: String {
        let style = Date.FormatStyle(timeZone: model.preferences.timeZone).month(.wide).day()
        return model.menuDate.formatted(model.calendar.component(.year, from: model.menuDate) == model.calendar.component(.year, from: model.now) ? style : style.year())
    }
    private func showDetail(_ event: CalendarEvent) {
        withAnimation(DayfoldMotion.standard(reduceMotion)) { detailKey = event.key }
    }
    private func dismissDetail() {
        withAnimation(DayfoldMotion.standard(reduceMotion)) { detailKey = nil }
    }
    private func showCalendar() {
        model.page = .calendar
        if let open = model.openCalendar { open() }
        else { openWindow(id: "calendar"); NSApp.activate(ignoringOtherApps: true) }
    }
    private func open(_ event: CalendarEvent) {
        model.selectedEvent = event
        model.selectedDate = event.time?.interval(in: model.preferences.timeZone).start ?? Date()
        model.dateChanged()
        showCalendar()
    }
}

private struct CompanionFocusEvent: View {
    @Bindable var model: AppModel
    let event: CalendarEvent
    let action: () -> Void
    @Environment(\.dayfoldReduceMotion) private var reduceMotion
    @State private var hovered = false
    private var sourceColor: Color { Color(calendarHex: model.calendars.first { $0.key == event.key.calendar }?.color ?? "#5578C5") }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Circle().fill(sourceColor).frame(width: 5, height: 5)
                    Text((event.time?.interval(in: model.preferences.timeZone).start ?? .distantFuture) <= model.now ? "Now" : "Up next")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
                }
                Text(String(event.title.prefix(30)))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.timeLabel(event)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    Text(model.sourceLabel(event.key.calendar)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    if let state = event.localState {
                        Label(state.label, systemImage: "clock.arrow.circlepath").font(.system(size: 10)).foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.primary.opacity(hovered ? 0.06 : 0.035), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(DayfoldPressStyle())
        .onHover { hovered = $0 }
        .animation(DayfoldMotion.quick(reduceMotion), value: hovered)
        .accessibilityLabel(model.accessibleEventLabel(event))
        .help(event.title + " · " + model.sourceLabel(event.key.calendar))
    }
}

private struct CompanionAgendaRow: View {
    @Bindable var model: AppModel
    let event: CalendarEvent
    let action: () -> Void
    @Environment(\.dayfoldReduceMotion) private var reduceMotion
    @State private var hovered = false
    private var sourceColor: Color { Color(calendarHex: model.calendars.first { $0.key == event.key.calendar }?.color ?? "#5578C5") }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                timeGutter
                    .frame(width: 54, alignment: .leading)
                RoundedRectangle(cornerRadius: 1).fill(sourceColor).frame(width: 2, height: 29)
                VStack(alignment: .leading, spacing: 5) {
                    Text(String(event.title.prefix(30)))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(model.sourceLabel(event.key.calendar))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    if let state = event.localState {
                        Label(state.label, systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(hovered ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(DayfoldPressStyle())
        .onHover { hovered = $0 }
        .animation(DayfoldMotion.quick(reduceMotion), value: hovered)
        .accessibilityLabel(model.accessibleEventLabel(event))
        .help(event.title + " · " + model.timeLabel(event) + " · " + model.sourceLabel(event.key.calendar))
    }

    @ViewBuilder private var timeGutter: some View {
        if let time = event.time, !time.isAllDay {
            let range = time.interval(in: model.preferences.timeZone)
            let style = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: model.preferences.timeZone)
            VStack(alignment: .leading, spacing: 5) {
                Text(range.start.formatted(style)).font(.system(size: 10, weight: .medium)).foregroundStyle(.primary)
                Text(range.end.formatted(style)).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .lineLimit(1)
        } else {
            Text("All day").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

extension AppModel {
    func saveQuickText() {
        let text = quickText, updated = Date(), repo = repository, destination = preferences.defaultCalendar
        Task { do { if text.isEmpty { try await repo?.discardDraft("quick-entry-text", at: updated) } else { try await repo?.saveDraft(EventDraft(id: "quick-entry-text", calendar: destination, fields: ["summary": .string(text), "quickInput": .string(text)], updated: updated)) } } catch { errorMessage = error.localizedDescription } }
    }
}
