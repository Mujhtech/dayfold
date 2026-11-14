import SwiftUI
import CalendarCore

struct MonthView: View {
    @Bindable var model: AppModel
    var body: some View {
        GeometryReader { geometry in
            let spans = MonthSpanLayout.spans(events: model.visibleEvents, gridStart: model.visibleRange.start, calendar: model.calendar)
            let rowHeight = max(116, (geometry.size.height - 32) / 6)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(0..<7) { index in
                        Text(model.calendar.shortWeekdaySymbols[(model.calendar.firstWeekday - 1 + index) % 7].uppercased())
                            .font(.system(size: 10, weight: .medium))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, 14)
                    }
                }
                .frame(height: 32)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5) }

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<6) { week in
                            MonthWeekView(model: model, week: week, spans: spans.filter { $0.week == week }, width: geometry.size.width, height: rowHeight)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
        }
    }
}

private struct MonthWeekView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    var week: Int
    var spans: [MonthSpan]
    var width: Double
    var height: Double
    private var columnWidth: Double { width / 7 }
    private var visibleRows: Int { min(2, (spans.map(\.row).max() ?? -1) + 1) }
    private var timedCapacity: Int { max(1, min(3, Int((height - 54 - Double(visibleRows * 20)) / 19))) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(0..<7) { column in dayCell(column) }
            }
            ForEach(spans.filter { $0.row < 2 }) { span in
                let color = Color(calendarHex: model.calendars.first { $0.key == span.event.key.calendar }?.color ?? "#5578C5")
                Button { model.selectedEvent = span.event } label: {
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2, height: 11)
                        Text(span.event.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                    }
                    .padding(.horizontal, 5)
                    .frame(width: columnWidth * Double(span.length) - 10, height: 18, alignment: .leading)
                    .foregroundStyle(.primary)
                    .background(color.opacity(model.selectedEvent?.id == span.event.id ? 0.22 : 0.11), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .offset(x: Double(span.column) * columnWidth + 5, y: Double(35 + span.row * 20))
                .accessibilityLabel(model.accessibleEventLabel(span.event))
            }
        }
        .frame(height: height)
    }

    private func dayCell(_ column: Int) -> some View {
        let day = model.calendar.date(byAdding: .day, value: week * 7 + column, to: model.visibleRange.start)!
        let range = model.calendar.dateInterval(of: .day, for: day)!
        let all = model.visibleEvents.filter { $0.time?.interval(in: model.preferences.timeZone).overlapsExclusive(range) ?? false }
        let spanIDs = Set(spans.map { $0.event.id })
        let timed = all.filter { !spanIDs.contains($0.id) }
        let visibleSpans = spans.filter { $0.row < 2 && ($0.column..<($0.column + $0.length)).contains(column) }.count
        let hidden = all.count - min(timed.count, timedCapacity) - visibleSpans
        let today = model.calendar.isDateInToday(day)
        let inMonth = model.calendar.isDate(day, equalTo: model.selectedDate, toGranularity: .month)

        return VStack(alignment: .leading, spacing: 0) {
            Button { show(day) } label: {
                Text("\(model.calendar.component(.day, from: day))")
                    .font(.system(size: 11, weight: today ? .semibold : .medium))
                    .monospacedDigit()
                    .frame(width: 24, height: 24)
                    .background(today ? Color.dayfoldAccent : .clear, in: Circle())
                    .foregroundStyle(today ? (colorScheme == .dark ? Color.black.opacity(0.85) : Color.white) : (inMonth ? Color.primary : Color.secondary.opacity(0.6)))
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
            .padding(.top, 6)
            .padding(.bottom, 5)

            Color.clear.frame(height: Double(visibleRows * 20))
            VStack(spacing: 1) {
                ForEach(timed.prefix(timedCapacity)) { event in
                    MonthEventRow(model: model, event: event)
                }
                if hidden > 0 {
                    Button("+\(hidden) more") { show(day) }
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, minHeight: 17, alignment: .leading)
                        .padding(.leading, 7)
                }
            }
            .padding(.horizontal, 5)
            Spacer(minLength: 0)
        }
        .frame(width: columnWidth, height: height, alignment: .topLeading)
        .background(inMonth ? Color.clear : Color.primary.opacity(0.018))
        .overlay(alignment: .trailing) { Rectangle().fill(Color.primary.opacity(0.06)).frame(width: 0.5) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5) }
    }

    private func show(_ date: Date) { model.selectedDate = date; model.mode = .agenda; model.dateChanged() }
}

private struct MonthEventRow: View {
    @Bindable var model: AppModel
    @Environment(\.dayfoldReduceMotion) private var reduceMotion
    let event: CalendarEvent
    @State private var hovered = false

    var body: some View {
        Button { model.selectedEvent = event } label: {
            HStack(spacing: 5) {
                Circle().fill(Color(calendarHex: model.calendars.first { $0.key == event.key.calendar }?.color ?? "#5578C5")).frame(width: 4, height: 4)
                Text(event.title).font(.system(size: 10, weight: .medium)).lineLimit(1)
                Spacer(minLength: 2)
                if let time = event.time {
                    Text(time.interval(in: model.preferences.timeZone).start.formatted(Date.FormatStyle(timeZone: model.preferences.timeZone).hour().minute()))
                        .font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(model.selectedEvent?.id == event.id ? Color.dayfoldAccent.opacity(0.09) : hovered ? Color.primary.opacity(0.045) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(DayfoldMotion.quick(reduceMotion), value: hovered)
        .accessibilityLabel(model.accessibleEventLabel(event))
    }
}

struct AgendaView: View {
    @Bindable var model: AppModel
    var events: [CalendarEvent]
    var emptyTitle: String
    private var groups: [(Date, [CalendarEvent])] {
        Dictionary(grouping: events) { event in model.calendar.startOfDay(for: max(model.visibleRange.start, event.time?.interval(in: model.preferences.timeZone).start ?? model.selectedDate)) }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        if events.isEmpty {
            ContentUnavailableView(emptyTitle, systemImage: "calendar", description: Text(model.searchText.isEmpty ? "Choose another date or adjust the visible calendars." : "Search covers permitted data downloaded for the selected dates."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    ForEach(groups, id: \.0) { day, events in
                        HStack(alignment: .top, spacing: 20) {
                            dateLabel(day)
                            VStack(spacing: 0) {
                                ForEach(events) { event in
                                    Button { model.selectedEvent = event } label: {
                                        AgendaRow(model: model, event: event)
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(model.accessibleEventLabel(event))
                                    if event.id != events.last?.id {
                                        Rectangle().fill(Color.primary.opacity(0.06)).frame(height: 0.5).padding(.leading, 120)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
    }

    private func dateLabel(_ day: Date) -> some View {
        let today = model.calendar.isDateInToday(day)
        return VStack(alignment: .leading, spacing: 5) {
            Text(day.formatted(Date.FormatStyle(timeZone: model.preferences.timeZone).weekday(.abbreviated)).uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(0.6)
                .foregroundStyle(today ? Color.dayfoldAccent : .secondary)
            Text("\(model.calendar.component(.day, from: day))")
                .font(.system(size: 27, weight: .regular))
                .monospacedDigit()
                .foregroundStyle(today ? Color.dayfoldAccent : .primary)
            Text(today ? "Today" : day.formatted(Date.FormatStyle(timeZone: model.preferences.timeZone).month(.abbreviated)))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(width: 48, alignment: .leading)
        .padding(.top, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.formatted(Date.FormatStyle(timeZone: model.preferences.timeZone).weekday(.wide).day().month(.wide)))
    }
}

struct AgendaRow: View {
    @Bindable var model: AppModel
    @Environment(\.dayfoldReduceMotion) private var reduceMotion
    let event: CalendarEvent
    @State private var hovered = false

    private var sourceDescription: String {
        let account = model.accounts.first { $0.id == event.key.calendar.account }?.label
        let calendar = model.calendars.first { $0.key == event.key.calendar }?.title
        if let account, let calendar, account.localizedCaseInsensitiveCompare(calendar) == .orderedSame { return calendar }
        return model.sourceLabel(event.key.calendar)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(model.timeLabel(event))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 92, alignment: .leading)

            RoundedRectangle(cornerRadius: 2)
                .fill(Color(calendarHex: model.calendars.first { $0.key == event.key.calendar }?.color ?? "#5578C5"))
                .frame(width: 3, height: 28)

            VStack(alignment: .leading, spacing: 5) {
                Text(event.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                HStack(spacing: 6) {
                    Text(sourceDescription).lineLimit(1).help(model.sourceLabel(event.key.calendar))
                    if let time = event.time, !time.isAllDay {
                        Text("·")
                        Text(Duration.seconds(time.interval(in: model.preferences.timeZone).duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                            .fixedSize()
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let state = event.localState { status(state.label, color: .orange) }
            else if event.response == "needsAction" { status("Invitation", color: .orange) }
            else if event.tentative { status("Tentative", color: .secondary) }
            else if event.response == "declined" { status("Declined", color: .secondary) }
            MeetingLinkControl(event: event)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .background(model.selectedEvent?.id == event.id ? Color.dayfoldAccent.opacity(0.07) : hovered ? Color.primary.opacity(0.025) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(DayfoldMotion.quick(reduceMotion), value: hovered)
    }

    private func status(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .foregroundStyle(color)
            .background(color.opacity(0.08), in: Capsule())
    }
}

struct MeetingLinkControl: View {
    let event: CalendarEvent
    var body: some View {
        let links = RichTextSafety.meetingLinks(event)
        if links.count == 1 { Link("Join", destination: links[0]).buttonStyle(.bordered).controlSize(.small) }
        else if links.count > 1 { Menu("Join…") { ForEach(links, id: \.self) { link in Link(link.host ?? "Meeting", destination: link) } }.controlSize(.small) }
    }
}
