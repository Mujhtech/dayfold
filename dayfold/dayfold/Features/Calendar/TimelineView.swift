import SwiftUI
import CalendarCore

struct TimelineView: View {
    @Bindable var model: AppModel
    @Environment(\.dayfoldReduceMotion) private var reduceMotion
    private var days: [Date] {
        let start = model.visibleRange.start
        return (0..<(model.mode == .day ? 1 : 7)).compactMap { model.calendar.date(byAdding: .day, value: $0, to: start) }.filter { model.preferences.showWeekends || model.mode == .day || !model.calendar.isDateInWeekend($0) }
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(model.preferences.timeZone.abbreviation() ?? "Time")
                    .font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 50)
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    let today = model.calendar.isDateInToday(day)
                    HStack(spacing: 5) {
                        Text(day.formatted(Date.FormatStyle(timeZone: model.preferences.timeZone).weekday(.abbreviated)))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Text("\(model.calendar.component(.day, from: day))")
                            .contentTransition(.numericText())
                            .font(.system(size: 11, weight: today ? .semibold : .medium)).monospacedDigit()
                            .foregroundStyle(today ? Color.dayfoldAccent : Color.primary)
                            .frame(width: 22, height: 22)
                            .background(today ? Color.dayfoldAccent.opacity(0.12) : .clear, in: Circle())
                        Spacer(minLength: 0)
                    }.padding(.leading, 8).frame(maxWidth: .infinity, minHeight: 36)
                        .animation(DayfoldMotion.standard(reduceMotion), value: day)
                }
            }
            HStack(alignment: .top, spacing: 0) {
                Text("all-day").font(.system(size: 9)).foregroundStyle(.tertiary).frame(width: 50).padding(.top, 8)
                ForEach(days, id: \.self) { day in
                    let range = model.calendar.dateInterval(of: .day, for: day)!
                    let events = model.visibleEvents.filter { $0.time?.isAllDay == true && ($0.time?.interval(in: model.preferences.timeZone).overlapsExclusive(range) ?? false) }
                    VStack(spacing: 3) {
                        ForEach(events.prefix(2)) { event in
                            Button { model.selectedEvent = event } label: { Text(event.title).font(.system(size: 10)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6).padding(.vertical, 3).background(color(event).opacity(0.08), in: RoundedRectangle(cornerRadius: 4)) }.buttonStyle(.plain)
                        }
                        if events.count > 2 { Button("+\(events.count - 2) more") { model.selectedDate = day; model.mode = .agenda; model.dateChanged() }.font(.caption2).buttonStyle(.plain) }
                    }.padding(.horizontal, 5).padding(.vertical, 4).frame(maxWidth: .infinity, minHeight: 32, alignment: .top)
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
                                }.foregroundStyle(.secondary).frame(width: 42, height: model.preferences.hourHeight, alignment: .topTrailing).padding(.trailing, 8).id(hour)
                            }
                        }
                        ForEach(days, id: \.self) { day in DayColumn(model: model, day: day, dayCount: days.count) }
                    }
                }
                .scrollIndicators(.never)
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
            let maximumColumns = geometry.size.width >= 148 ? 2 : 1
            let overflow = TimelineDensity.overflow(placements, maximumColumns: maximumColumns)
            ZStack(alignment: .topLeading) {
                Rectangle().fill(model.calendar.isDateInToday(day) ? Color.dayfoldAccent.opacity(0.025) : Color.primary.opacity(0.001))
                    .onTapGesture(count: 2) { point in model.newDraft(start: instant(point.y)) }
                    .gesture(DragGesture(minimumDistance: 12).onEnded { value in
                        let a = instant(min(value.startLocation.y, value.location.y)), b = instant(max(value.startLocation.y, value.location.y))
                        model.newDraft(start: a, end: max(a.addingTimeInterval(900), b))
                    })
                ForEach(0..<Int(ceil(range.duration / 3600)), id: \.self) { hour in
                    let date = range.start.addingTimeInterval(Double(hour) * 3600)
                    let localHour = model.calendar.component(.hour, from: date)
                    if localHour < model.preferences.workStart || localHour >= model.preferences.workEnd {
                        Rectangle().fill(Color.primary.opacity(0.018)).frame(height: model.preferences.hourHeight).offset(y: Double(hour) * model.preferences.hourHeight).allowsHitTesting(false)
                    }
                    Rectangle().fill(Color.primary.opacity(0.065)).frame(height: 0.5).offset(y: Double(hour) * model.preferences.hourHeight).allowsHitTesting(false)
                    if range.duration != 86400 {
                        Text(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: model.preferences.timeZone)) + " " + (model.preferences.timeZone.abbreviation(for: date) ?? ""))
                            .font(.system(size: 8)).foregroundStyle(.secondary).offset(x: 3, y: Double(hour) * model.preferences.hourHeight).allowsHitTesting(false)
                    }
                }
                Rectangle().fill(Color.primary.opacity(0.065)).frame(width: 0.5).allowsHitTesting(false)
                ForEach(placements.filter { $0.columns <= maximumColumns || $0.column < maximumColumns - 1 }) { placement in
                    let width = max(1, (geometry.size.width - 8) / Double(min(maximumColumns, placement.columns)))
                    EventBlock(model: model, event: placement.event, hourHeight: model.preferences.hourHeight, dayWidth: geometry.size.width)
                        .frame(width: max(1, width - 4), height: max(25, placement.end.timeIntervalSince(placement.start) / 3600 * model.preferences.hourHeight - 3))
                        .offset(x: Double(placement.column) * width + 4, y: placement.start.timeIntervalSince(range.start) / 3600 * model.preferences.hourHeight)
                }
                ForEach(overflow) { group in
                    let members = placements.filter { $0.groupID == group.id && $0.column >= maximumColumns - 1 }
                    let width = max(1, (geometry.size.width - 8) / Double(maximumColumns))
                    let end = members.map(\.end).max() ?? group.start.addingTimeInterval(1800)
                    let height = max(28, end.timeIntervalSince(group.start) / 3600 * model.preferences.hourHeight - 3)
                    Button {
                        model.selectedDate = day; model.mode = .agenda; model.dateChanged()
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 4) {
                                Image(systemName: "square.stack").font(.system(size: 9))
                                Text("\(group.count) events").font(.system(size: 10, weight: .medium))
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.system(size: 8))
                            }.foregroundStyle(.secondary)
                            if height >= 58 {
                                ForEach(Array(members.prefix(height >= 90 ? 3 : 1))) { member in
                                    HStack(alignment: .top, spacing: 5) {
                                        Circle().fill(Color(calendarHex: model.calendars.first { $0.key == member.event.key.calendar }?.color ?? "#5578C5")).frame(width: 4, height: 4).padding(.top, 5)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(member.event.title).font(.system(size: 11)).lineLimit(1)
                                            if height >= 120 { Text(model.timeLabel(member.event)).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1) }
                                        }
                                    }
                                }
                            }
                            Spacer(minLength: 0)
                        }.padding(7).frame(width: max(1, width - 4), height: height, alignment: .topLeading)
                            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.primary.opacity(0.08), lineWidth: 0.5))
                    }.buttonStyle(.plain).help(members.map { $0.event.title + " · " + model.timeLabel($0.event) }.joined(separator: "\n"))
                        .accessibilityLabel("Show \(group.count) overlapping events in the agenda")
                        .offset(x: Double(maximumColumns - 1) * width + 4, y: group.start.timeIntervalSince(range.start) / 3600 * model.preferences.hourHeight)
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
    @State private var hovered = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dayfoldReduceMotion) private var reduceMotion
    private var color: Color { Color(calendarHex: model.calendars.first { $0.key == event.key.calendar }?.color ?? "#5578C5") }
    var body: some View {
        Button { model.selectedEvent = event } label: {
            GeometryReader { geometry in
                blockContents(size: geometry.size)
            }
            .foregroundStyle(.primary)
            .background(color.opacity(event.response == "declined" ? 0.05 : colorScheme == .dark ? (hovered ? 0.17 : 0.11) : hovered ? 0.12 : 0.07))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(model.selectedEvent?.id == event.id ? color : hovered ? color.opacity(0.45) : color.opacity(0.16), lineWidth: model.selectedEvent?.id == event.id ? 1.5 : 0.5))
            .animation(DayfoldMotion.quick(reduceMotion), value: hovered)

        }.buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(helpText)
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
    private var helpText: String {
        var parts = [event.title, model.timeLabel(event), model.sourceLabel(event.key.calendar)]
        if let state = event.localState { parts.append(state.label) }
        return parts.joined(separator: " · ")
    }
    private func blockContents(size: CGSize) -> some View {
        let titleLines: Int = size.height > 54 ? 2 : 1
        return
                HStack(spacing: 0) {
                    Rectangle().fill(color.opacity(0.8)).frame(width: 2)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .top, spacing: 3) {
                            Text(event.title).font(.system(size: 11, weight: .medium))
                                .lineLimit(titleLines)
                                .strikethrough(event.response == "declined")
                            if let state = event.localState { Image(systemName: "clock.arrow.circlepath").font(.system(size: 8)).foregroundStyle(.secondary).padding(.top, 2).accessibilityLabel(state.label) }
                        }
                        if size.height > 36 {
                            HStack(spacing: 3) {
                                Text(blockTime(compact: size.width < 108)).font(.system(size: 9)).monospacedDigit().lineLimit(1)
                            }.foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }.padding(.horizontal, 6).padding(.top, size.height > 36 ? 6 : 4)
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func blockTime(compact: Bool) -> String {
        guard compact, let time = event.time else { return model.timeLabel(event) }
        return time.interval(in: model.preferences.timeZone).start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: model.preferences.timeZone))
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
