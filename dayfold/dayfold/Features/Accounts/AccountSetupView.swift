import SwiftUI
import CalendarCore

struct AccountSetupView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Make room for your calendars").font(.title2.bold())
            Text("Choose the calendars to download. Visibility in the sidebar can change independently later.").foregroundStyle(.secondary)
            List {
                ForEach(model.accounts) { account in
                    Section(account.email) {
                        ForEach(model.calendars.filter { $0.key.account == account.id && !$0.deleted }) { source in
                            Toggle(isOn: Binding(get: { source.syncEnabled }, set: { enabled in Task { do { try await model.repository?.setCalendarChoices(source.key, visible: enabled, syncEnabled: enabled) } catch { model.errorMessage = error.localizedDescription } } })) {
                                VStack(alignment: .leading, spacing: 4) { Text(source.title); Text([source.primary ? "Primary" : "Shared / secondary", source.role, source.hidden ? "Hidden in Google" : ""].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                }
            }
            Picker("New events use", selection: Binding(get: { model.preferences.defaultCalendar?.id ?? "" }, set: { id in model.preferences.defaultCalendar = model.calendars.first { $0.id == id }?.key; model.savePreferences() })) { Text("Choose a writable calendar").tag(""); ForEach(model.calendars.filter { $0.writable && $0.syncEnabled }) { Text(model.sourceLabel($0.key)).tag($0.id) } }
            HStack { Text("Google account identity is always shown before a write.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Open Calendar") { model.showAccountSetup = false; Task { await model.refresh() } }.buttonStyle(.borderedProminent) }
        }.padding(26).frame(width: 600, height: 560)
    }
}
