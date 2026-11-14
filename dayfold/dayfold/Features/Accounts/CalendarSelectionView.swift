import SwiftUI
import CalendarCore

/// Shared by the first-run guide and the sheet for adding another account.
struct CalendarSelectionView: View {
    @Bindable var model: AppModel

    private var available: [CalendarSource] { model.calendars.filter { !$0.deleted } }
    private var defaults: [CalendarSource] { available.filter { $0.writable && $0.syncEnabled } }
    private var busy: Bool { model.isSavingCalendarSelection || model.isLoading }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Group {
                if available.isEmpty { emptyState }
                else {
                    List {
                        ForEach(model.accounts) { account in
                            Section {
                                let sources = available.filter { $0.key.account == account.id }
                                if sources.isEmpty {
                                    Text("No calendars found for this account.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(sources) { source in calendarRow(source) }
                            } header: {
                                Text(account.email).font(.system(size: 11, weight: .medium))
                                    .textCase(nil).lineLimit(1).help(account.email)
                            }
                        }
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 5) {
                Picker("New events use", selection: Binding(
                    get: { defaults.first { $0.key == model.preferences.defaultCalendar }?.id ?? "" },
                    set: { id in saveDefault(defaults.first { $0.id == id }?.key) }
                )) {
                    Text(defaults.isEmpty ? "No writable calendars selected" : "Choose a calendar").tag("")
                    ForEach(defaults) { source in Text(model.sourceLabel(source.key)).tag(source.id) }
                }
                .disabled(busy || defaults.isEmpty)
                .accessibilityIdentifier("onboarding-default-calendar")
                if defaults.isEmpty, !available.isEmpty {
                    Text("You can still browse your selected calendars. Select a writable calendar to create events.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            if model.isRefreshing || model.isConnecting {
                ProgressView("Loading your calendars…").controlSize(.small)
            } else {
                Image(systemName: "calendar.badge.exclamationmark")
                    .font(.system(size: 24, weight: .light)).foregroundStyle(.secondary)
                Text("Your calendars haven’t loaded yet").font(.headline)
                Text("Refresh to try again. You can also finish setup and choose calendars in Settings later.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Refresh Calendars") { Task { await model.refresh() } }
                    .disabled(model.isLoading)
            }
        }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func calendarRow(_ source: CalendarSource) -> some View {
        Toggle(isOn: Binding(get: { source.syncEnabled }, set: { setEnabled($0, for: source) })) {
            HStack(spacing: 9) {
                Circle().fill(Color(calendarHex: source.color)).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.title).font(.system(size: 13)).lineLimit(1).help(source.title)
                    Text([source.primary ? "Primary calendar" : "", !source.writable ? "Read only" : "", source.hidden ? "Hidden in Google" : ""].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 3)
        }
        .toggleStyle(.checkbox)
        .disabled(busy)
        .accessibilityLabel("Download \(source.title)")
    }

    private func setEnabled(_ enabled: Bool, for source: CalendarSource) {
        guard !busy, let repository = model.repository else { return }
        let generation = model.sessionGeneration
        model.isSavingCalendarSelection = true
        Task {
            defer { if generation == model.sessionGeneration { model.isSavingCalendarSelection = false } }
            do {
                try await repository.setCalendarChoices(source.key, visible: enabled, syncEnabled: enabled)
                guard generation == model.sessionGeneration else { return }
                if !enabled, model.preferences.defaultCalendar == source.key {
                    let calendars = try await repository.calendars()
                    guard generation == model.sessionGeneration else { return }
                    let next = calendars.first { $0.writable && $0.syncEnabled && !$0.deleted }
                    var preferences = model.preferences
                    preferences.defaultCalendar = next?.key
                    try await repository.setPreferences(preferences)
                    guard generation == model.sessionGeneration else { return }
                    model.preferences.defaultCalendar = next?.key
                }
                await model.reload()
            } catch {
                guard generation == model.sessionGeneration else { return }
                model.errorMessage = error.localizedDescription
            }
        }
    }

    private func saveDefault(_ key: CalendarKey?) {
        guard !busy, let repository = model.repository else { return }
        let generation = model.sessionGeneration
        model.isSavingCalendarSelection = true
        var preferences = model.preferences
        preferences.defaultCalendar = key
        Task {
            defer { if generation == model.sessionGeneration { model.isSavingCalendarSelection = false } }
            do {
                try await repository.setPreferences(preferences)
                guard generation == model.sessionGeneration else { return }
                model.preferences.defaultCalendar = key
                await model.reload()
            } catch {
                guard generation == model.sessionGeneration else { return }
                model.errorMessage = error.localizedDescription
            }
        }
    }
}
