import SwiftUI
import UserNotifications
import CalendarCore
import CalendarPlatform

struct OnboardingRemindersView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var requesting = false
    @State private var permissionError: String?

    private var enabled: Bool {
        model.preferences.notifications && (authorization == .authorized || authorization == .provisional)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "bell.badge").font(.system(size: 23)).foregroundStyle(Color.dayfoldAccent)
                VStack(alignment: .leading, spacing: 6) {
                    Text("A moment to get ready").font(.system(size: 14, weight: .medium))
                    Text("Reminders follow each event’s reminder times. You can snooze an alert or jump straight to the event.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                }
            }
            if model.isDemo {
                Label("Demo doesn’t send notifications.", systemImage: "sparkle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Text("When you connect Google, you can enable reminders here or in Settings → Reminders.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                if enabled {
                    Label("Reminders are on", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.dayfoldAccent).font(.system(size: 13, weight: .medium))
                } else if authorization == .denied {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Notifications are turned off in macOS.").font(.system(size: 13, weight: .medium))
                        Text("You can enable Dayfold in System Settings → Notifications, then return here. It’s fine to continue without reminders.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Button(requesting ? "Waiting for permission…" : "Enable Reminders") { requestPermission() }
                        .controlSize(.large).disabled(requesting || model.notifications == nil)
                }
                Toggle("Keep event titles private in alerts", isOn: $model.preferences.privateNotifications)
                    .font(.system(size: 12))
                    .onChange(of: model.preferences.privateNotifications) { model.savePreferences() }
                Text("Private alerts use “Busy event” instead of the event title.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, -15)
            }
            if let permissionError {
                Text(permissionError).font(.system(size: 12)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Reminders are optional. You can change your choice in Settings anytime.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .task { await refreshPermission() }
        .onChange(of: scenePhase) { if scenePhase == .active { Task { await refreshPermission() } } }
    }

    private func refreshPermission() async {
        let generation = model.sessionGeneration
        guard let status = await model.notifications?.permission(), generation == model.sessionGeneration else { return }
        authorization = status
    }

    private func requestPermission() {
        guard !model.isDemo, !requesting, let scheduler = model.notifications else { return }
        requesting = true; permissionError = nil
        let generation = model.sessionGeneration
        Task {
            defer { requesting = false }
            do {
                let granted = try await scheduler.requestPermission()
                let status = await scheduler.permission()
                guard generation == model.sessionGeneration, !model.isDemo else { return }
                authorization = status
                model.notificationPermission = granted ? "Allowed" : "Not allowed — enable Dayfold in System Settings"
                model.preferences.notifications = granted
                model.savePreferences()
            } catch {
                guard generation == model.sessionGeneration else { return }
                permissionError = error.localizedDescription
            }
        }
    }
}
