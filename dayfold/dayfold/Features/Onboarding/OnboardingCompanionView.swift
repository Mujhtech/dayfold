import SwiftUI
import CalendarPlatform
import KeyboardShortcuts

struct OnboardingCompanionView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "menubar.rectangle").font(.system(size: 22))
                    .foregroundStyle(Color.dayfoldAccent).frame(width: 28)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your day in the menu bar").font(.system(size: 14, weight: .medium))
                    Text("Click Dayfold’s calendar icon at the top of your screen for upcoming events. Closing the calendar window keeps it there.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                }
            }
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "keyboard").font(.system(size: 22))
                    .foregroundStyle(Color.dayfoldAccent).frame(width: 28)
                VStack(alignment: .leading, spacing: 8) {
                    Text("A shortcut for a new plan").font(.system(size: 14, weight: .medium))
                    Text("Type something like “Lunch tomorrow at 1pm.” Review the details before saving.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                    KeyboardShortcuts.Recorder("Quick Entry", name: .dayfoldQuickEntry)
                        .font(.system(size: 12))
                    Text("Also available in the Calendar menu.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("Start the day with Dayfold").font(.system(size: 13, weight: .medium))
                    Spacer()
                    if model.loginStatus == "Enabled" {
                        Label("Enabled", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(Color.dayfoldAccent)
                    } else if !model.isDemo {
                        if model.loginStatus == "Approval required in System Settings" {
                            Button("System Settings…") { PlatformServices.openLoginSettings() }
                        } else {
                            Button("Enable launch at login", action: enableLogin)
                                .disabled(model.loginStatus == "Unavailable")
                        }
                    }
                }
                Text(model.isDemo ? "Launch at login is available after connecting Google." : model.loginStatus == "Approval required in System Settings" ? "Approve Dayfold in Login Items to finish enabling it." : "Optionally open Dayfold in the menu bar when you log in to your Mac.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let loginError { Text(loginError).font(.system(size: 11)).foregroundStyle(.red) }
            }
        }
        .onAppear { model.loginStatus = PlatformServices.loginStatus }
        .onChange(of: scenePhase) { if scenePhase == .active { model.loginStatus = PlatformServices.loginStatus } }
    }

    private func enableLogin() {
        guard !model.isDemo else { return }
        do {
            try PlatformServices.setLogin(true)
            model.loginStatus = PlatformServices.loginStatus
            loginError = nil
        } catch { loginError = error.localizedDescription }
    }
}
