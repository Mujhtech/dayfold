import SwiftUI
import CalendarCore

/// The calendar beside the planning conversation. This reads its own day snapshot
/// so navigating the preview never depends on the main calendar's visible range.
struct AssistantDayPreview: View {
    @Bindable var model: AppModel
    @State private var loaded: LoadedDay?
    @State private var loadError: String?
    @State private var retry = 0
    @State private var hoveredEvent: String?

    private struct LoadKey: Equatable {
        let generation: Int
        let day: LocalDate
        let zone: String
        let retry: Int
        let isLoading: Bool
    }

    private struct LoadedDay {
        let key: LoadKey
        let context: AssistantDayContext
        let events: [EventKey: CalendarEvent]
        let sources: [CalendarKey: CalendarSource]
        let labels: [CalendarKey: String]
    }

    private struct Row: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let eventKey: EventKey?
        var proposed: Bool { eventKey == nil }
    }

    private var zone: TimeZone { model.preferences.timeZone }
    private var day: LocalDate { LocalDate(model.assistantPreviewDate, zone: zone) }
    private var dayDate: Date { day.start(in: zone) }
    private var loadKey: LoadKey {
        LoadKey(generation: model.sessionGeneration, day: day, zone: zone.identifier, retry: retry, isLoading: model.isLoading)
    }
    private var current: LoadedDay? { loaded?.key == loadKey ? loaded : nil }
    private var rows: [Row] {
        var result = current?.context.events.map {
            Row(id: $0.key.id, title: $0.title, start: $0.start, end: $0.end, allDay: $0.isAllDay, eventKey: $0.key)
        } ?? []
        if let proposal = model.assistantProposal, let proposalZone = model.assistantProposalZone,
           let time = try? proposal.validatedTime(in: proposalZone) {
            let range = time.interval(in: zone)
            let selectedDay = DateInterval(start: dayDate, end: day.adding(days: 1).start(in: zone))
            if range.overlapsExclusive(selectedDay) {
                result.append(Row(id: "assistant-proposed-event", title: proposal.title, start: range.start, end: range.end, allDay: false, eventKey: nil))
            }
        }
        return result.sorted {
            if $0.allDay != $1.allDay { return $0.allDay }
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.id < $1.id
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.55)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let loadError, current == nil {
                        loadFailure(loadError)
                    } else if current == nil {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text("Loading this day…").font(.system(size: 12)).foregroundStyle(.secondary)
                        }.padding(.top, 34)
                    } else if rows.isEmpty {
                        emptyDay
                    } else {
                        ForEach(rows) { row in
                            if row.proposed {
                                scheduleRow(row)
                                    .accessibilityElement(children: .combine)
                            } else {
                                Button { openEvent(row) } label: { scheduleRow(row) }
                                    .buttonStyle(.plain)
                                    .onHover { hoveredEvent = $0 ? row.id : nil }
                                    .help("Open event in Calendar")
                                    .accessibilityLabel("\(row.title), \(timeDescription(row)). Open in Calendar.")
                            }
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .scrollIndicators(.never)
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: loadKey) { await observeDay(key: loadKey, zone: zone) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(dayDate.formatted(Date.FormatStyle(timeZone: zone).weekday(.wide)))
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                HStack(spacing: 1) {
                    Button { moveDay(-1) } label: {
                        Image(systemName: "chevron.left").font(.system(size: 10, weight: .medium)).frame(width: 23, height: 25)
                    }.help("Previous day").accessibilityLabel("Preview previous day")
                    Button("Today") { model.assistantPreviewDate = Date() }
                        .font(.system(size: 11)).padding(.horizontal, 5).frame(height: 25)
                        .accessibilityLabel("Preview today")
                    Button { moveDay(1) } label: {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .medium)).frame(width: 23, height: 25)
                    }.help("Next day").accessibilityLabel("Preview next day")
                }
                .buttonStyle(DayfoldPressStyle())
                .disabled(model.isLoading || model.isShowingOnboarding)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(dayDate.formatted(Date.FormatStyle(timeZone: zone).month(.wide).day()))
                    .font(.system(size: 24, weight: .medium, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                Text(zone.abbreviation(for: dayDate) ?? zone.identifier)
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .help(zone.identifier)
            }
        }
        .padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 20)
    }

    private func scheduleRow(_ row: Row) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 4) {
                Text(row.allDay ? "All day" : row.start < dayDate ? "Earlier" : clock(row.start))
                    .font(.system(size: 11, weight: row.proposed ? .medium : .regular))
                    .foregroundStyle(row.proposed ? Color.dayfoldAccent : Color.secondary)
                if !row.allDay {
                    Text(row.end >= day.adding(days: 1).start(in: zone) ? "Continues" : clock(row.end))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.85)
            .frame(width: 50, alignment: .trailing).padding(.top, row.proposed ? 12 : 3)

            if row.proposed {
                VStack(alignment: .leading, spacing: 7) {
                    Text("PROPOSED").font(.system(size: 9, weight: .semibold))
                        .tracking(0.8).foregroundStyle(Color.dayfoldAccent)
                    Text(row.title).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                    Text("Waiting for your review").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.dayfoldAccent.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.dayfoldAccent.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            } else {
                HStack(alignment: .top, spacing: 9) {
                    Circle().fill(color(for: row)).frame(width: 5, height: 5).padding(.top, 7)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(row.title).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.primary).lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(row.eventKey.flatMap { current?.labels[$0.calendar] } ?? "Calendar")
                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        if let event = row.eventKey.flatMap({ current?.events[$0] }), let state = event.localState {
                            Text(state.label).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, row.proposed ? 14 : 15)
        .background(hoveredEvent == row.id ? Color.primary.opacity(0.025) : .clear, in: RoundedRectangle(cornerRadius: 4))
        .overlay(alignment: .bottom) {
            if !row.proposed { Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5).padding(.leading, 62) }
        }
        .contentShape(Rectangle())
    }

    private var emptyDay: some View {
        VStack(alignment: .leading, spacing: 13) {
            Image(systemName: "sun.horizon").font(.system(size: 25, weight: .light))
                .foregroundStyle(Color.dayfoldAccent.opacity(0.65))
                .padding(.bottom, 4)
            Text("No events to show").font(.system(size: 14, weight: .medium))
            Text(current?.context.availabilityIsReliable == true
                 ? "Plans for this day will appear here."
                 : "This day may not be fully downloaded yet. Your saved calendar data is shown here as it becomes available.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 38).padding(.leading, 10).padding(.trailing, 18)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().padding(.bottom, 8)
            HStack(spacing: 5) {
                Image(systemName: "square.stack").font(.system(size: 10))
                Text("All synced calendars").font(.system(size: 11, weight: .medium))
            }.foregroundStyle(.secondary)
            Text(coverageDescription)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
        }
        .padding(.horizontal, 20).padding(.bottom, 18)
    }

    private var coverageDescription: String {
        guard let context = current?.context else { return loadError == nil ? "Reading saved events for this day." : "Calendar data is temporarily unavailable." }
        if context.calendars.isEmpty { return "No calendars have synchronization enabled." }
        let scope = context.excludedCalendarCount > 0 ? " Calendars with sync turned off are excluded." : " Includes calendars hidden from the main view."
        if !context.calendars.allSatisfy(\.isComplete) { return "Some calendars aren’t downloaded for this date." + scope }
        if !context.calendars.allSatisfy(\.isFresh) { return "Showing cached events; some may have changed." + scope }
        if context.eventsTruncated { return "Showing the first \(context.events.count) downloaded events." + scope }
        if context.invalidEventCount > 0 { return "Some event times couldn’t be read." + scope }
        return "Downloaded events for this day." + scope
    }

    private func loadFailure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Couldn’t load this day").font(.system(size: 14, weight: .medium))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Try again") { retry += 1 }.font(.system(size: 12))
        }.padding(.top, 34)
    }

    private func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
    }

    private func timeDescription(_ row: Row) -> String {
        if row.allDay { return "All day" }
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: zone)
        return "\(row.start.formatted(style)) to \(row.end.formatted(style))"
    }

    private func color(for row: Row) -> Color {
        guard let key = row.eventKey, let source = current?.sources[key.calendar] else { return .dayfoldAccent }
        return Color(calendarHex: source.color)
    }

    private func moveDay(_ direction: Int) {
        model.assistantPreviewDate = day.adding(days: direction).start(in: zone)
    }

    private func openEvent(_ row: Row) {
        guard let key = row.eventKey, let event = current?.events[key] else { return }
        model.page = .calendar
        model.selectedDate = dayDate
        model.selectedEvent = event
        model.dateChanged()
    }

    private func observeDay(key: LoadKey, zone: TimeZone) async {
        guard !Task.isCancelled, key == loadKey else { return }
        loadError = nil
        guard !key.isLoading else { return }
        guard let repository = model.repository else {
            loaded = nil
            loadError = "Open a calendar account to see your day here."
            return
        }
        let interval = DateInterval(start: key.day.start(in: zone), end: key.day.adding(days: 1).start(in: zone))
        for await _ in await repository.changes() {
            guard !Task.isCancelled, key == loadKey else { return }
            do {
                let snapshot = try await repository.snapshot(interval: interval, displayZone: zone)
                guard !Task.isCancelled, key == loadKey else { return }
                let context = try AssistantDayContext(snapshot: snapshot, day: key.day, timeZone: zone, maximumEvents: 500)
                let accounts = Dictionary(snapshot.accounts.map { ($0.id, $0.label) }, uniquingKeysWith: { _, newer in newer })
                let labels = Dictionary(snapshot.calendars.map { source in
                    let account = accounts[source.key.account] ?? ""
                    let label = account.isEmpty || account == source.title ? source.title : account + " · " + source.title
                    return (source.key, label)
                }, uniquingKeysWith: { _, newer in newer })
                loaded = LoadedDay(key: key, context: context,
                    events: Dictionary(snapshot.events.map { ($0.key, $0) }, uniquingKeysWith: { _, newer in newer }),
                    sources: Dictionary(snapshot.calendars.map { ($0.key, $0) }, uniquingKeysWith: { _, newer in newer }), labels: labels)
                loadError = nil
            } catch {
                guard !Task.isCancelled, key == loadKey else { return }
                loadError = "Your saved calendar data couldn’t be read. Try again in a moment."
                loaded = nil
            }
        }
    }
}
