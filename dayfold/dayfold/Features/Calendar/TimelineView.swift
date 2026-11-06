import SwiftUI
import CalendarCore

struct TimelineView: View {
    @Bindable var model: AppModel
    private var days: [Date] {
        let start = model.visibleRange.start
        return (0..<(model.mode == .day ? 1 : 7)).compactMap { model.calendar.date(byAdding: .day, value: $0, to: start) }.filter { model.preferences.showWeekends || model.mode == .day || !model.calendar.isDateInWeekend($0) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(model.preferences.timeZone.abbreviation() ?? "Time").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 64)
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 5) {
                        Text(day.formatted(Date.FormatStyle(timeZone: model.preferences.timeZone).weekday(.abbreviated))).textCase(.uppercase).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        Text("\(model.calendar.component(.day, from: day))").font(.system(size: 23, weight: .medium, design: .rounded)).frame(width: 36, height: 36).background(model.calendar.isDateInToday(day) ? Color.accentColor : Color.clear, in: Circle()).foregroundStyle(model.calendar.isDateInToday(day) ? Color.white : Color.primary)
                    }.frame(maxWidth: .infinity).padding(.vertical, 12)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                Text("all-day").font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 64).padding(.top, 8)
                ForEach(days, id: \.self) { day in
                    let range = model.calendar.dateInterval(of: .day, for: day)!
                    let events = model.visibleEvents.filter { $0.time?.isAllDay == true && ($0.time?.interval(in: model.preferences.timeZone).overlapsExclusive(range) ?? false) }
                    VStack(spacing: 3) {
                        ForEach(events.prefix(2)) { event in
                            Button { model.selectedEvent = event } label: { Text(event.title).font(.system(size: 10, weight: .medium)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 4).background(color(event).opacity(0.16), in: RoundedRectangle(cornerRadius: 4)) }.buttonStyle(.plain)
                        }
                        if events.count > 2 { Button("+\(events.count - 2) more") { model.selectedDate = day; model.mode = .agenda; model.dateChanged() }.font(.caption2).buttonStyle(.plain) }
                    }.padding(4).frame(maxWidth: .infinity, minHeight: 34, alignment: .top)
                }
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            ForEach(0..<25) { hour in
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(hourLabel(hour)).font(.system(size: 10))
                                    if let secondary = TimeZone(identifier: model.preferences.secondaryZone) {
                                        let date = model.visibleRange.start.addingTimeInterval(Double(hour) * 3600)
                                        Text(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: secondary))).font(.system(size: 8)).opacity(0.7)
                                    }
                                }.foregroundStyle(.secondary).frame(width: 56, height: model.preferences.hourHeight, alignment: .topTrailing).padding(.trailing, 8).id(hour)
                            }
                        }
                        ForEach(days, id: \.self) { day in DayColumn(model: model, day: day, dayCount: days.count) }
                    }
                }
                .onAppear { proxy.scrollTo(model.preferences.workStart, anchor: .top) }
            }
        }
    }
    private func color(_ event: CalendarEvent) -> Color { Color(calendarHex: model.calendars.first { $0.key == event.key.calendar }?.color ?? "#5578C5") }
    private func hourLabel(_ hour: Int) -> String {
        let date = model.calendar.date(bySettingHour: hour % 24, minute: 0, second: 0, of: model.selectedDate) ?? model.selectedDate
        return date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: model.preferences.timeZone))
    }
}

private struct DayColumn: View {
    @Bindable var model: AppModel
    let day: Date
    let dayCount: Int
    private var range: DateInterval { model.calendar.dateInterval(of: .day, for: day)! }
    private var height: Double { range.duration / 3600 * model.preferences.hourHeight }
    var body: some View {
        GeometryReader { geometry in
            let placements = TimelineLayout.place(model.visibleEvents, day: range, zone: model.preferences.timeZone)
            let maximumColumns = max(1, Int(geometry.size.width / 70))
            let overflow = TimelineDensity.overflow(placements, maximumColumns: maximumColumns)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.primary.opacity(0.001))
                    .onTapGesture(count: 2) { point in model.newDraft(start: instant(point.y)) }
                    .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                        let a = instant(min(value.startLocation.y, value.location.y)), b = instant(max(value.startLocation.y, value.location.y))
                        model.newDraft(start: a, end: max(a.addingTimeInterval(900), b))
                    })
                ForEach(0..<Int(ceil(range.duration / 3600)), id: \.self) { hour in
                    let date = range.start.addingTimeInterval(Double(hour) * 3600)
                    let localHour = model.calendar.component(.hour, from: date)
                    if localHour < model.preferences.workStart || localHour >= model.preferences.workEnd {
                        Rectangle().fill(Color.primary.opacity(0.025)).frame(height: model.preferences.hourHeight).offset(y: Double(hour) * model.preferences.hourHeight).allowsHitTesting(false)
                    }
                    Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5).offset(y: Double(hour) * model.preferences.hourHeight).allowsHitTesting(false)
                    if range.duration != 86400 {
                        Text(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: model.preferences.timeZone)) + " " + (model.preferences.timeZone.abbreviation(for: date) ?? ""))
                            .font(.system(size: 8)).foregroundStyle(.secondary).offset(x: 3, y: Double(hour) * model.preferences.hourHeight).allowsHitTesting(false)
                    }
                }
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 0.5).allowsHitTesting(false)
                ForEach(placements.filter { $0.columns <= maximumColumns || $0.column < maximumColumns - 1 }) { placement in
                    let width = max(1, (geometry.size.width - 6) / Double(min(maximumColumns, placement.columns)))
                    EventBlock(model: model, event: placement.event, hourHeight: model.preferences.hourHeight, dayWidth: geometry.size.width)
                        .frame(width: width - 3, height: max(25, placement.end.timeIntervalSince(placement.start) / 3600 * model.preferences.hourHeight - 2))
                        .offset(x: Double(placement.column) * width + 3, y: placement.start.timeIntervalSince(range.start) / 3600 * model.preferences.hourHeight)
                }
                ForEach(overflow) { group in
                    let width = max(1, (geometry.size.width - 6) / Double(maximumColumns))
                    Button {
                        model.selectedDate = day; model.mode = .agenda; model.dateChanged()
                    } label: {
                        Text("+\(group.count)\nevents").font(.system(size: 10, weight: .semibold)).multilineTextAlignment(.leading)
                            .frame(width: width - 3, height: 42).background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    }.buttonStyle(.plain).accessibilityLabel("Show \(group.count) overlapping events in the agenda")
                        .offset(x: Double(maximumColumns - 1) * width + 3, y: group.start.timeIntervalSince(range.start) / 3600 * model.preferences.hourHeight)
                }
                if range.contains(model.now) {
                    HStack(spacing: 0) { Circle().frame(width: 6, height: 6); Rectangle().frame(height: 1) }.foregroundStyle(.red).offset(y: model.now.timeIntervalSince(range.start) / 3600 * model.preferences.hourHeight).allowsHitTesting(false)
                }
            }
        }.frame(height: height)
    }
    private func instant(_ y: Double) -> Date { range.start.addingTimeInterval(max(0, min(range.duration - 900, (y / model.preferences.hourHeight * 4).rounded() * 900))) }
}

private struct EventBlock: View {
    @Bindable var model: AppModel
    let event: CalendarEvent
    let hourHeight: Double
    let dayWidth: Double
    @State private var drag = CGSize.zero
    @State private var cancelled = false
    private var color: Color { Color(calendarHex: model.calendars.first { $0.key == event.key.calendar }?.color ?? "#5578C5") }
    var body: some View {
        Button { model.selectedEvent = event } label: {
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title).font(.system(size: 11, weight: .semibold)).lineLimit(2)
                    Text(model.timeLabel(event)).font(.system(size: 9)).lineLimit(1).opacity(0.85)
                    if event.localState != nil { Image(systemName: "clock.arrow.circlepath").font(.system(size: 9)).accessibilityLabel("Pending synchronization") }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 6).padding(.vertical, 5)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.primary).background(color.opacity(event.response == "declined" ? 0.06 : 0.14), in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(model.selectedEvent?.id == event.id ? color : color.opacity(0.16), lineWidth: model.selectedEvent?.id == event.id ? 1.5 : 0.5))
            .clipped()
        }.buttonStyle(.plain)
        .accessibilityLabel(model.accessibleEventLabel(event))
        .offset(drag)
        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { value in
            if model.capability(.edit, event: event).allowed && !cancelled { drag = value.translation }
        }.onEnded { value in
            defer { drag = .zero; cancelled = false }
            guard !cancelled, model.capability(.edit, event: event).allowed else { return }
            model.proposeMove(event, minutes: Int((value.translation.height / hourHeight * 4).rounded()) * 15, days: Int((value.translation.width / dayWidth).rounded()), resize: false)
        })
        .overlay(alignment: .bottom) {
            if model.capability(.edit, event: event).allowed {
                Color.clear.frame(height: 6).contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 4).onEnded { value in
                    model.proposeMove(event, minutes: Int((value.translation.height / hourHeight * 4).rounded()) * 15, days: 0, resize: true)
                }).help("Drag to resize, or edit the end time")
            }
        }
        .onExitCommand { cancelled = true; drag = .zero }
        .contextMenu {
            Button("Edit Event") { model.edit(event) }.disabled(!model.capability(.edit, event: event).allowed)
            Button("Duplicate to Calendar…") { model.duplicate(event) }.disabled(event.redacted)
            Button("Open in Google Calendar") { model.openGoogle(event) }
        }
    }
}

extension AppModel {
    func accessibleEventLabel(_ event: CalendarEvent) -> String {
        let date = event.time?.interval(in: preferences.timeZone).start.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: preferences.timeZone)) ?? "Date unavailable"
        return "\(event.title), \(date), \(timeLabel(event)), \(sourceLabel(event.key.calendar)), \(event.localState?.label ?? event.response)"
    }
    func timeLabel(_ event: CalendarEvent) -> String {
        guard let time = event.time else { return "Time unavailable" }
        if case .allDay = time { return "All day" }
        let r = time.interval(in: preferences.timeZone), style = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: preferences.timeZone)
        return r.start.formatted(style) + "–" + r.end.formatted(style)
    }
    func proposeMove(_ event: CalendarEvent, minutes: Int, days: Int, resize: Bool) {
        guard case .timed(let start, let end, let sz, let ez) = event.time else { return }
        let movedStart = resize ? start : calendar.date(byAdding: .day, value: days, to: start)!.addingTimeInterval(Double(minutes * 60))
        let movedEnd = calendar.date(byAdding: .day, value: days, to: end)!.addingTimeInterval(Double(minutes * 60))
        guard movedEnd > movedStart else { errorMessage = "The end must be after the start."; return }
        var fields = event.raw; fields.merge(EventTime.timed(start: movedStart, end: movedEnd, startZone: sz, endZone: ez).providerFields) { _, v in v }
        let draft = EventDraft(calendar: event.key.calendar, source: event, fields: fields)
        Task { do { try await repository?.saveDraft(draft); editingDraft = draft } catch { errorMessage = error.localizedDescription } }
    }
}
