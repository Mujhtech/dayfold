import SwiftUI
import CalendarCore

struct SidebarView: View {
    @Bindable var model: AppModel
    @Environment(\.dayfoldReduceMotion) private var reduceMotion
    @Namespace private var navigationSelection
    @State private var setName = ""
    @State private var savingSet = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(spacing: 2) {
                        if model.preferences.experienceMode == .assistant {
                            navigationRow("Assistant", symbol: "text.bubble", page: .assistant)
                        }
                        navigationRow("Calendar", symbol: "calendar", page: .calendar)
                        navigationRow("Invitations", symbol: "tray", page: .invitations, count: model.menuEvents.filter { $0.response == "needsAction" }.count)
                        navigationRow("Pending Changes", symbol: "arrow.triangle.2.circlepath", page: .pending, count: model.pending.count)
                    }.animation(DayfoldMotion.standard(reduceMotion), value: model.page)

                    MiniMonthView(model: model).padding(.horizontal, 4)

                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.accounts) { account in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(account.label)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                ForEach(model.calendars.filter { $0.key.account == account.id && !$0.deleted }) { source in
                                    Button { model.setVisibility(source, !source.visible) } label: {
                                        HStack(spacing: 8) {
                                            Image(systemName: source.visible ? "checkmark.square.fill" : "square")
                                                .font(.system(size: 11))
                                                .foregroundStyle(Color(calendarHex: source.color))
                                                .frame(width: 13)
                                            Text(source.title)
                                                .lineLimit(1)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.primary)
                                            Spacer(minLength: 2)
                                            if !source.writable {
                                                Image(systemName: source.freeBusyOnly ? "eye.slash" : "lock")
                                                    .font(.system(size: 8))
                                                    .foregroundStyle(.tertiary)
                                                    .help(source.role)
                                            }
                                        }
                                        .padding(.horizontal, 8)
                                        .frame(height: 24)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(SidebarRowStyle())
                                    .accessibilityLabel("\(source.visible ? "Hide" : "Show") \(source.title)")
                                }
                            }
                        }
                    }

                    HStack {
                        Menu {
                            Button("All calendars") { model.setVisibilitySet("All") }
                            ForEach(model.preferences.savedSets.keys.sorted(), id: \.self) { name in
                                Button(name) { model.setVisibilitySet(name) }
                            }
                            Divider()
                            Button("Save current set…") { savingSet = true }
                        } label: {
                            Label("Calendar sets", systemImage: "square.stack")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            footer
        }
        .alert("Save visibility set", isPresented: $savingSet) {
            TextField("Name", text: $setName)
            Button("Save") {
                let name = setName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    model.preferences.savedSets[name] = Set(model.calendars.filter(\.visible).map(\.id))
                    model.savePreferences()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func navigationRow(_ title: String, symbol: String, page: SidebarPage, count: Int = 0) -> some View {
        let selected = model.page == page
        return Button { model.page = page } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 14)
                    .foregroundStyle(selected ? Color.dayfoldAccent : .secondary)
                Text(title)
                    .font(.system(size: 11, weight: selected ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06))
                        .matchedGeometryEffect(id: "selected-page", in: navigationSelection)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowStyle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            if model.isDemo {
                HStack(spacing: 5) {
                    Text(model.demoOffline ? "Demo · Offline" : "Demo · Local only")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Menu {
                        Toggle("Simulate offline", isOn: Binding(get: { model.demoOffline }, set: model.simulateOffline))
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Demo controls — fictional events on this Mac")
                }
                .accessibilityLabel(model.demoOffline ? "Demo, fictional events, offline" : "Demo, fictional events stored on this Mac")
            }
            HStack {
                Button {
                    if model.isDemo { Task { await model.loadStore(demo: false) } }
                    else { model.connect() }
                } label: {
                    Label("Add account", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(model.isDemo ? "Switch to your Google accounts" : "Connect another Google account")
                Spacer(minLength: 8)
                SettingsLink { Text("Settings").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 20)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }
}

private struct SidebarRowStyle: ButtonStyle {
    @Environment(\.dayfoldReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(configuration.isPressed ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 4))
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(DayfoldMotion.quick(reduceMotion), value: configuration.isPressed)
    }
}

struct MiniMonthView: View {
    @Bindable var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dayfoldReduceMotion) private var reduceMotion
    @Namespace private var dateSelection

    var body: some View {
        let cal = model.calendar
        let first = cal.dateInterval(of: .month, for: model.selectedDate)!.start
        let start = cal.dateInterval(of: .weekOfYear, for: first)!.start
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                Text(first.formatted(Date.FormatStyle(timeZone: model.preferences.timeZone).month(.wide).year()))
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 3)
                monthArrow(-1)
                monthArrow(1)
            }
            .padding(.horizontal, 3)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 1) {
                ForEach(0..<7) { i in
                    Text(cal.veryShortWeekdaySymbols[(cal.firstWeekday - 1 + i) % 7])
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .frame(height: 14)
                }
                ForEach(0..<42) { i in
                    let date = cal.date(byAdding: .day, value: i, to: start)!
                    let selected = cal.isDate(date, inSameDayAs: model.selectedDate)
                    let today = cal.isDateInToday(date)
                    Button { model.selectedDate = date; model.page = .calendar; model.dateChanged() } label: {
                        Text("\(cal.component(.day, from: date))")
                            .font(.system(size: 10, weight: selected || today ? .medium : .regular))
                            .monospacedDigit()
                            .frame(width: 21, height: 21)
                            .foregroundStyle(selected ? (colorScheme == .dark ? Color.black.opacity(0.85) : Color.white) : today ? Color.dayfoldAccent : cal.isDate(date, equalTo: first, toGranularity: .month) ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.45))
                            .background {
                                if selected {
                                    RoundedRectangle(cornerRadius: 4).fill(Color.dayfoldAccent)
                                        .matchedGeometryEffect(id: "selected-date", in: dateSelection)
                                } else if today {
                                    RoundedRectangle(cornerRadius: 4).fill(Color.dayfoldAccent.opacity(0.08))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(date.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: model.preferences.timeZone)))
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }.animation(DayfoldMotion.standard(reduceMotion), value: model.selectedDate)
        }
    }

    private func monthArrow(_ direction: Int) -> some View {
        Button { model.selectedDate = model.calendar.date(byAdding: .month, value: direction, to: model.selectedDate)!; model.dateChanged() } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(direction < 0 ? "Previous month" : "Next month")
    }
}

extension Color {
    init(calendarHex: String) {
        let hex = calendarHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(hex, radix: 16) ?? 0x5578C5
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
