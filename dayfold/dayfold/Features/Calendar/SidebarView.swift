import SwiftUI
import CalendarCore

struct SidebarView: View {
    @Bindable var model: AppModel
    @State private var setName = ""
    @State private var savingSet = false
    var body: some View {
        VStack(spacing: 0) {
            HStack { Image(systemName: "calendar").foregroundStyle(.tint); Text("Dayfold").font(.system(size: 20, weight: .semibold, design: .rounded)); Spacer() }.padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 20)
            MiniMonthView(model: model).padding(.horizontal, 14).padding(.bottom, 16)
            List {
                Section {
                    Button { model.page = .calendar } label: { Label("Calendar", systemImage: "calendar") }.buttonStyle(.plain)
                    Button { model.page = .invitations } label: { Label("Invitations", systemImage: "tray") }.buttonStyle(.plain)
                    Button { model.page = .pending } label: { HStack { Label("Pending Changes", systemImage: "arrow.triangle.2.circlepath"); Spacer(); if !model.pending.isEmpty { Text("\(model.pending.count)").foregroundStyle(.secondary) } } }.buttonStyle(.plain)
                }
                ForEach(model.accounts) { account in
                    Section(account.label.uppercased()) {
                        ForEach(model.calendars.filter { $0.key.account == account.id && !$0.deleted }) { source in
                            HStack(spacing: 8) {
                                Button { model.setVisibility(source, !source.visible) } label: { Image(systemName: source.visible ? "checkmark.square.fill" : "square").foregroundStyle(Color(calendarHex: source.color)) }.buttonStyle(.plain).accessibilityLabel("\(source.visible ? "Hide" : "Show") \(source.title)")
                                Text(source.title).lineLimit(1)
                                Spacer(minLength: 2)
                                if !source.writable { Image(systemName: source.freeBusyOnly ? "eye.slash" : "lock").font(.caption2).foregroundStyle(.secondary).help(source.role) }
                            }.padding(.vertical, 3)
                        }
                    }
                }
                Section("VISIBILITY SETS") {
                    Button("All calendars") { model.setVisibilitySet("All") }.buttonStyle(.plain)
                    ForEach(model.preferences.savedSets.keys.sorted(), id: \.self) { name in Button(name) { model.setVisibilitySet(name) }.buttonStyle(.plain) }
                    Button { savingSet = true } label: { Label("Save current set", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }.listStyle(.sidebar)
            Divider()
            HStack { Button { model.connect() } label: { Label("Add Account", systemImage: "person.badge.plus") }.buttonStyle(.plain); Spacer(); SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.plain) }.padding(18)
        }
        .alert("Save visibility set", isPresented: $savingSet) { TextField("Name", text: $setName); Button("Save") { let name = setName.trimmingCharacters(in: .whitespaces); if !name.isEmpty { model.preferences.savedSets[name] = Set(model.calendars.filter(\.visible).map(\.id)); model.savePreferences() } }; Button("Cancel", role: .cancel) {} }
    }
}

struct MiniMonthView: View {
    @Bindable var model: AppModel
    var body: some View {
        let cal = model.calendar
        let first = cal.dateInterval(of: .month, for: model.selectedDate)!.start
        let start = cal.dateInterval(of: .weekOfYear, for: first)!.start
        VStack(spacing: 9) {
            HStack { Text(first.formatted(Date.FormatStyle(timeZone: model.preferences.timeZone).month(.wide).year())).font(.caption.bold()); Spacer(); Button { model.selectedDate = cal.date(byAdding: .month, value: -1, to: model.selectedDate)!; model.dateChanged() } label: { Image(systemName: "chevron.left") }; Button { model.selectedDate = cal.date(byAdding: .month, value: 1, to: model.selectedDate)!; model.dateChanged() } label: { Image(systemName: "chevron.right") } }.buttonStyle(.plain)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 7), spacing: 4) {
                ForEach(0..<7) { i in Text(cal.veryShortWeekdaySymbols[(cal.firstWeekday - 1 + i) % 7]).font(.system(size: 10)).foregroundStyle(.secondary) }
                ForEach(0..<42) { i in
                    let date = cal.date(byAdding: .day, value: i, to: start)!
                    let selected = cal.isDate(date, inSameDayAs: model.selectedDate)
                    Button { model.selectedDate = date; model.page = .calendar; model.dateChanged() } label: {
                        Text("\(cal.component(.day, from: date))").font(.system(size: 11, weight: selected ? .semibold : .regular)).frame(width: 24, height: 24)
                            .foregroundStyle(selected ? Color.white : cal.isDate(date, equalTo: first, toGranularity: .month) ? Color.primary : Color.secondary.opacity(0.5))
                            .background(selected ? Color.accentColor : Color.clear, in: Circle())
                    }.buttonStyle(.plain).accessibilityLabel(date.formatted(Date.FormatStyle(date: .complete, time: .omitted, timeZone: model.preferences.timeZone)))
                }
            }
        }
    }
}

extension Color {
    init(calendarHex: String) {
        let hex = calendarHex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = UInt64(hex, radix: 16) ?? 0x5578C5
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}
