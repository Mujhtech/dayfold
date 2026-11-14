import SwiftUI
import CalendarCore

struct AccountSetupView: View {
    @Bindable var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Make room for your calendars").font(.title2.bold())
            Text("Choose the calendars to download. Visibility in the sidebar can change independently later.").foregroundStyle(.secondary)
            CalendarSelectionView(model: model)
            HStack { Text("Google account identity is always shown before a write.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Open Calendar") { model.showAccountSetup = false; Task { await model.refresh() } }.buttonStyle(.borderedProminent).disabled(model.isSavingCalendarSelection) }
        }.padding(26).frame(width: 600, height: 560)
    }
}
