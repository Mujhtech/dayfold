import SwiftUI
import CalendarCore

struct MonthView: View {
    @Bindable var model: AppModel
    var body: some View {
        GeometryReader { geometry in
            let spans = MonthSpanLayout.spans(events: model.visibleEvents, gridStart: model.visibleRange.start, calendar: model.calendar)
            let rowHeight = max(108, (geometry.size.height - 34) / 6)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(0..<7) { index in Text(model.calendar.shortWeekdaySymbols[(model.calendar.firstWeekday - 1 + index) % 7].uppercased()).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 10) }
                }
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(0..<6) { week in
                            MonthWeekView(model: model, week: week, spans: spans.filter { $0.week == week }, width: geometry.size.width, height: rowHeight)
                        }
                    }
                }
            }
        }
    }
}
private struct MonthWeekView: View {
    @Bindable var model: AppModel
    var week: Int
    var spans: [MonthSpan]
    var width: Double
    var height: Double
    private var columnWidth: Double { width / 7 }
    var body: some View {
        let visibleRows = min(2, (spans.map(\.row).max() ?? -1) + 1)
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(0..<7) { column in
                    let day = model.calendar.date(byAdding: .day, value: week * 7 + column, to: model.visibleRange.start)!
                    let range = model.calendar.dateInterval(of: .day, for: day)!
                    let all = model.visibleEvents.filter { $0.time?.interval(in: model.preferences.timeZone).overlapsExclusive(range) ?? false }
                    let spanIDs = Set(spans.map { $0.event.id })
                    let timed = all.filter { !spanIDs.contains($0.id) }
                    let visibleSpans = spans.filter { $0.row < 2 && ($0.column..<($0.column + $0.length)).contains(column) }.count
                    VStack(alignment: .leading, spacing: 3) {
                        Button { show(day) } label: {
                            Text("\(model.calendar.component(.day, from: day))").font(.system(size: 12, weight: .medium)).frame(width: 25, height: 25).background(model.calendar.isDateInToday(day) ? Color.accentColor : .clear, in: Circle()).foregroundStyle(model.calendar.isDateInToday(day) ? Color.white : Color.primary)
                        }.buttonStyle(.plain)
                        Color.clear.frame(height: Double(visibleRows * 19))
                        ForEach(timed.prefix(2)) { event in
                            Button { model.selectedEvent = event } label: { HStack(spacing: 3) { Circle().fill(Color(calendarHex: model.calendars.first { $0.key == event.key.calendar }?.color ?? "#5578C5")).frame(width: 4, height: 4); Text(event.title).font(.system(size: 10)).lineLimit(1); Spacer(minLength: 0) } }.buttonStyle(.plain).accessibilityLabel(model.accessibleEventLabel(event))
                        }
                        let hidden = all.count - min(timed.count, 2) - visibleSpans
                        if hidden > 0 { Button("+\(hidden) more") { show(day) }.font(.caption2).buttonStyle(.plain).foregroundStyle(.secondary) }
                        Spacer(minLength: 0)
                    }.padding(6).frame(width: columnWidth, height: height, alignment: .topLeading)
                        .background(model.calendar.isDate(day, equalTo: model.selectedDate, toGranularity: .month) ? .clear : Color.primary.opacity(0.025))
                        .border(Color.primary.opacity(0.06), width: 0.5)
                }
            }
            ForEach(spans.filter { $0.row < 2 }) { span in
                let color = Color(calendarHex: model.calendars.first { $0.key == span.event.key.calendar }?.color ?? "#5578C5")
                Button { model.selectedEvent = span.event } label: {
                    Text(span.event.title).font(.system(size: 10, weight: .medium)).lineLimit(1).padding(.horizontal, 6).frame(width: columnWidth * Double(span.length) - 6, height: 17, alignment: .leading).foregroundStyle(.primary).background(color.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                }.buttonStyle(.plain).offset(x: Double(span.column) * columnWidth + 3, y: Double(34 + span.row * 19))
                    .accessibilityLabel(model.accessibleEventLabel(span.event))
            }
        }.frame(height: height)
    }
    private func show(_ date: Date) { model.selectedDate = date; model.mode = .agenda; model.dateChanged() }
}

struct AgendaView: View {
    @Bindable var model: AppModel
    var events: [CalendarEvent]
    var emptyTitle: String
    private var groups: [(Date, [CalendarEvent])] {
        Dictionary(grouping: events) { event in model.calendar.startOfDay(for: max(model.visibleRange.start, event.time?.interval(in: model.preferences.timeZone).start ?? model.selectedDate)) }.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
    var body: some View {
        if events.isEmpty { ContentUnavailableView(emptyTitle, systemImage: "calendar", description: Text(model.searchText.isEmpty ? "Choose another date or adjust the visible calendars." : "Search covers permitted data downloaded for the selected dates.")) }
        else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    ForEach(groups, id: \.0) { day, events in
                        VStack(alignment: .leading, spacing: 0) {
                            Text(day.formatted(Date.FormatStyle(timeZone: model.preferences.timeZone).weekday(.wide).day().month(.wide))).font(.headline).padding(.bottom, 12)
                            ForEach(events) { event in
                                Button { model.selectedEvent = event } label: { AgendaRow(model: model, event: event) }.buttonStyle(.plain).accessibilityLabel(model.accessibleEventLabel(event))
                                Divider().padding(.leading, 128)
                            }
                        }
                    }
                }.padding(26)
            }
        }
    }
}
struct AgendaRow: View {
    @Bindable var model: AppModel
    let event: CalendarEvent
    var body: some View {
        HStack(spacing: 16) {
            Text(model.timeLabel(event)).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary).frame(width: 108, alignment: .leading)
            RoundedRectangle(cornerRadius: 2).fill(Color(calendarHex: model.calendars.first { $0.key == event.key.calendar }?.color ?? "#5578C5")).frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(event.title).font(.system(size: 13, weight: .medium))
                Text(model.sourceLabel(event.key.calendar)).font(.caption).foregroundStyle(.secondary)
                if let time = event.time, !time.isAllDay { Text(Duration.seconds(time.interval(in: model.preferences.timeZone).duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))).font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer()
            if let state = event.localState { Text(state.label).font(.caption2).foregroundStyle(.orange) }
            else if event.response == "needsAction" { Text("Invitation").font(.caption).foregroundStyle(.orange) }
            else if event.tentative { Text("Tentative").font(.caption).foregroundStyle(.secondary) }
            else if event.response == "declined" { Text("Declined").font(.caption).foregroundStyle(.secondary) }
            MeetingLinkControl(event: event)
        }.padding(.vertical, 14).contentShape(Rectangle())
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
