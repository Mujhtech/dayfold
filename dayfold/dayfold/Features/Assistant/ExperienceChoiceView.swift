import SwiftUI
import CalendarCore

/// Chooses a workspace preference only. Selecting Assistant does not run a
/// model, grant permissions, or change any calendar event.
struct ExperienceChoiceView: View {
    @Bindable var model: AppModel
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            option(.calendar, title: "Calendar", symbol: "calendar",
                   detail: "Browse your days and make changes yourself.")
            option(.assistant, title: "With an assistant", symbol: "text.bubble",
                   detail: "Ask about your schedule, find open time, and review suggested events before saving.")
            if model.preferences.experienceMode == .assistant {
                Text("Connect your own OpenAI API key. You approve every change.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text("You can switch anytime in Settings. Your full calendar is available in either mode.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                .padding(.top, compact ? 0 : 3)
        }
    }

    private func option(_ experience: DayfoldExperience, title: String, symbol: String, detail: String) -> some View {
        let selected = model.preferences.experienceMode == experience
        return Button {
            guard model.preferences.experienceMode != experience else { return }
            model.preferences.experienceMode = experience
            model.savePreferences()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: compact ? 18 : 21))
                    .foregroundStyle(selected ? Color.dayfoldAccent : Color.secondary)
                    .frame(width: 26).padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: compact ? 13 : 14, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(selected ? Color.dayfoldAccent : Color.secondary.opacity(0.5))
                    .padding(.top, 1)
            }
            .padding(compact ? 12 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.dayfoldAccent.opacity(0.06) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Color.dayfoldAccent.opacity(0.65) : Color.primary.opacity(0.12), lineWidth: selected ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(detail)
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .accessibilityIdentifier("experience-" + experience.rawValue)
    }
}
