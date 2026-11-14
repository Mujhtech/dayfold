import SwiftUI
import AppKit
import CalendarCore
import CalendarPlatform
import KeyboardShortcuts
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var model: AppModel
    var body: some View {
        TabView {
            AccountsSettings(model: model).tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            Form {
                Section("Your workspace") {
                    ExperienceChoiceView(model: model, compact: true)
                }
                if model.preferences.experienceMode == .assistant {
                    Section("Assistant connection") { AssistantConnectionView(model: model) }
                }
                Section("Calendar") {
                    Picker("Start with", selection: $model.preferences.startupView) { Text("Restore last view").tag("restore"); ForEach(CalendarViewMode.allCases) { Text($0.rawValue).tag($0.rawValue) } }
                    Picker("Default calendar", selection: Binding(get: { model.preferences.defaultCalendar?.id ?? "" }, set: { id in model.preferences.defaultCalendar = model.calendars.first { $0.id == id }?.key; model.savePreferences() })) { Text("Choose a calendar").tag(""); ForEach(model.calendars.filter(\.writable)) { Text(model.sourceLabel($0.key)).tag($0.id) } }
                    Stepper("Default duration: \(model.preferences.defaultDuration) minutes", value: $model.preferences.defaultDuration, in: 15...240, step: 15)
                    Picker("Week starts", selection: $model.preferences.weekStart) { Text("System locale").tag(0); Text("Sunday").tag(1); Text("Monday").tag(2); Text("Saturday").tag(7) }
                    Toggle("Show weekends", isOn: $model.preferences.showWeekends)
                    Toggle("Show declined events", isOn: $model.preferences.showDeclined)
                    Stepper("Workday begins: \(model.preferences.workStart):00", value: $model.preferences.workStart, in: 0...23)
                    Stepper("Workday ends: \(model.preferences.workEnd):00", value: $model.preferences.workEnd, in: 1...24)
                    HStack { Text("Timeline density"); Slider(value: $model.preferences.hourHeight, in: 44...100, step: 4) }
                }
                Section("Appearance & time zones") {
                    Picker("Appearance", selection: $model.preferences.appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                    TextField("Display zone (device or IANA identifier)", text: $model.preferences.displayZone)
                    TextField("Secondary zone (optional)", text: $model.preferences.secondaryZone)
                    Text("Changing display zones never changes your Google events.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Launch at login") {
                    Text(model.loginStatus)
                    HStack { Button("Enable") { setLogin(true) }; Button("Disable") { setLogin(false) }; Button("System Settings…") { PlatformServices.openLoginSettings() } }
                }
            }.formStyle(.grouped).tabItem { Label("General", systemImage: "slider.horizontal.3") }
            Form {
                Section("Menu bar") {
                    Picker("Label", selection: $model.preferences.menuStyle) { Text("Next meeting time").tag("time"); Text("Countdown").tag("countdown"); Text("Icon only").tag("icon") }
                    Toggle("Include tentative meetings in Up Next", isOn: $model.preferences.includeTentative)
                }
                Section("Quick entry") {
                    KeyboardShortcuts.Recorder("Global shortcut", name: .dayfoldQuickEntry)
                    Text("You can always open Quick Entry from the Calendar menu. Shortcut registration requires no Accessibility permission.").font(.caption).foregroundStyle(.secondary)
                    Text("English parser · dates and times are always previewed. Use YYYY-MM-DD for unambiguous dates.").font(.caption)
                }
            }.formStyle(.grouped).tabItem { Label("Quick Entry", systemImage: "keyboard") }
            Form {
                Section("Notifications") {
                    Text("Permission: \(model.notificationPermission)")
                    Button("Enable notifications…") { Task { do { let granted = try await model.notifications?.requestPermission() ?? false; model.preferences.notifications = granted; model.notificationPermission = granted ? "Allowed" : "Not allowed — enable Dayfold in System Settings"; model.savePreferences() } catch { model.errorMessage = error.localizedDescription } } }
                    Toggle("Deliver local event reminders", isOn: $model.preferences.notifications)
                    Toggle("Use “Busy event” for notification titles", isOn: $model.preferences.privateNotifications)
                    Stepper("All-day reminder hour: \(model.preferences.allDayHour):00 in calendar zone", value: $model.preferences.allDayHour, in: 0...23)
                    Stepper("Snooze: \(model.preferences.snoozeMinutes) minutes", value: $model.preferences.snoozeMinutes, in: 1...60)
                    Text("Google email reminders are delivered by Google. Previously scheduled system reminders may appear after quitting; they cannot refresh while Dayfold is closed. Delivery depends on macOS, Focus, and sleep.").font(.caption).foregroundStyle(.secondary)
                    if model.isDemo { Text("Demo does not schedule event reminders.").font(.caption).foregroundStyle(.orange) }
                }
            }.formStyle(.grouped).tabItem { Label("Reminders", systemImage: "bell") }
            RelaySettingsView(model: model).tabItem { Label("Real-time", systemImage: "bolt.horizontal") }
            AdvancedSettings(model: model).tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .scrollIndicators(.never)
        .onChange(of: model.preferences) { model.savePreferences() }
        .task { if let status = await model.notifications?.permission() { model.notificationPermission = String(describing: status); model.loginStatus = PlatformServices.loginStatus } }
        .alert("Dayfold", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
    }
    private func setLogin(_ enabled: Bool) { do { try PlatformServices.setLogin(enabled); model.loginStatus = PlatformServices.loginStatus } catch { model.errorMessage = error.localizedDescription } }
}

private struct AccountsSettings: View {
    @Bindable var model: AppModel
    @State private var disconnecting: CalendarAccount?
    @State private var stopping: CalendarSource?
    @State private var labeling: CalendarAccount?
    @State private var accountLabel = ""
    var body: some View {
        Form {
            if model.isDemo { Section { Label("Isolated demo store", systemImage: "sparkle"); Button("Switch to Google accounts") { Task { await model.loadStore(demo: false) } } } }
            ForEach(model.accounts) { account in
                Section(account.label) {
                    LabeledContent("Google identity", value: account.email)
                    Button("Edit local label…") { accountLabel = account.label; labeling = account }
                    LabeledContent("Status", value: account.status.label)
                    HStack { Button("Reconnect") { model.connect(expected: account) }.disabled(model.isDemo); Button("Disconnect…", role: .destructive) { disconnecting = account } }
                    ForEach(model.calendars.filter { $0.key.account == account.id }) { source in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Circle().fill(Color(calendarHex: source.color)).frame(width: 8, height: 8); Text(source.title); Spacer(); Text(source.primary ? "Primary" : source.role).font(.caption).foregroundStyle(.secondary) }
                            Toggle("Synchronize", isOn: Binding(get: { source.syncEnabled }, set: { enabled in if !enabled { stopping = source } else { Task { try? await model.repository?.setCalendarChoices(source.key, syncEnabled: true); await model.refresh() } } })).disabled(source.deleted)
                        }
                    }
                }
            }
            Section { Button(model.isConnecting ? "Waiting for Google…" : "Add Google Account") { model.connect() }.disabled(model.isConnecting); if model.isConnecting { Button("Cancel sign-in") { model.auth.cancel() } }; if !model.auth.configuration.configured { Text("Connection setup: add a Google Desktop OAuth client to Config/OAuth.local.json and rebuild. Demo is available without credentials.").font(.caption).foregroundStyle(.secondary) } }
        }.formStyle(.grouped)
        .alert("Local account label", isPresented: Binding(get: { labeling != nil }, set: { if !$0 { labeling = nil } })) {
            TextField("Label", text: $accountLabel)
            Button("Save") { if let account = labeling { Task { do { try await model.repository?.setAccountLabel(account.id, label: accountLabel) } catch { model.errorMessage = error.localizedDescription } } }; labeling = nil }
            Button("Cancel", role: .cancel) { labeling = nil }
        } message: { Text("This name is used on this Mac. Your Google account identity stays visible in account settings.") }
        .confirmationDialog("Disconnect this account?", isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }), titleVisibility: .visible) {
            Button("Export pending work, then disconnect") { if let account = disconnecting { model.disconnect(account, export: true) }; disconnecting = nil }
            Button("Discard local work and disconnect", role: .destructive) { if let account = disconnecting { model.disconnect(account, export: false) }; disconnecting = nil }
            Button("Cancel", role: .cancel) { disconnecting = nil }
        } message: { Text("Removes this account's credentials, cache, reminders, drafts, and pending changes from this Mac. Google events remain in Google. Export first to preserve local work.") }
        .confirmationDialog("Stop synchronizing this calendar?", isPresented: Binding(get: { stopping != nil }, set: { if !$0 { stopping = nil } }), titleVisibility: .visible) { Button("Stop syncing") { if let source = stopping { Task { try? await model.repository?.setCalendarChoices(source.key, syncEnabled: false) } }; stopping = nil }; Button("Cancel", role: .cancel) { stopping = nil } } message: { Text("Cached events become stale. Pending edits remain saved and will wait until synchronization is enabled again. Hiding a calendar in the sidebar only changes visibility.") }
    }
}

private struct AdvancedSettings: View {
    @Bindable var model: AppModel
    @State private var rebuild = false
    @State private var reset = false
    var body: some View {
        Form {
            Section("Cache & recovery") {
                Text("\(model.coverage.count) downloaded date windows · \(model.pending.count) pending changes · \(model.drafts.count) drafts")
                Button("Export pending changes and drafts…") { Task { _ = await model.exportRecovery() } }
                Button("Rebuild remote cache…") { rebuild = true }
                Button("Reset this local store…", role: .destructive) { reset = true }
                Text("Rebuilding preserves drafts, pending changes, and conflicts. Existing cache stays visible until complete replacement pages arrive.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                Text("Dayfold 1.0 · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                ForEach(model.accounts) { account in LabeledContent(account.label, value: account.status.label) }
                Button("Export redacted diagnostics…") { exportDiagnostics() }
                Text("Includes versions, status categories, and counts. No tokens, event text, guest addresses, or meeting links.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") { Text("Dayfold connects directly to Google and keeps calendar data on this Mac. Credentials are kept in Keychain. An optional Dayfold account for real-time updates stores account and device information, routing IDs, and reminder times; the relay does not store event details. If you use the assistant, requests and relevant event titles and times are sent to OpenAI with your API key. Dayfold has no analytics. The local cache uses macOS protections and is not separately encrypted.").font(.callout); Text("Offline recurrence is limited to downloaded ranges. Structural recurring edits require online review. This and following, busy mirroring, other providers, billing, and automatic updates are not enabled.").font(.caption).foregroundStyle(.secondary) }
        }.formStyle(.grouped)
        .confirmationDialog("Rebuild Google's cached data?", isPresented: $rebuild) { Button("Rebuild and refresh") { Task { do { try await model.repository?.rebuildRemoteCache(); await model.refresh() } catch { model.errorMessage = error.localizedDescription } } }; Button("Cancel", role: .cancel) {} }
        .confirmationDialog("Remove this store's local data?", isPresented: $reset, titleVisibility: .visible) {
            Button("Export pending work, then reset") { model.resetLocalStore(exportFirst: true) }
            Button("Discard local work and reset", role: .destructive) { model.resetLocalStore(exportFirst: false) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Removes connected accounts, credentials, cache, drafts, pending changes, reminders, and preferences for this store. Google events remain in Google. A request already sent to Google may still finish. Demo and Google stores are separate.") }
    }
    private func exportDiagnostics() {
        let report: JSONObject = ["app": .string("Dayfold 1.0"), "os": .string(ProcessInfo.processInfo.operatingSystemVersionString), "accounts": .number(Double(model.accounts.count)), "calendars": .number(Double(model.calendars.count)), "pending": .number(Double(model.pending.count)), "drafts": .number(Double(model.drafts.count)), "windows": .number(Double(model.coverage.count)), "statuses": .array(model.accounts.map { .string($0.status.rawValue) }), "errors": .array(model.pending.compactMap(\.errorCategory).map(JSONValue.string)), "demo": .bool(model.isDemo)]
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Dayfold-diagnostics.json"; panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { do { try JSONEncoder().encode(report).write(to: url, options: .atomic) } catch { model.errorMessage = error.localizedDescription } }
    }
}
