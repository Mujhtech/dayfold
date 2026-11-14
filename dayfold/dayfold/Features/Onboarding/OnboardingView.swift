import SwiftUI
import AppKit
import CalendarPlatform
import CalendarCore

struct OnboardingView: View {
    @Bindable var model: AppModel
    @Environment(\.dayfoldReduceMotion) private var reduceMotion
    @State private var showingPrivacy = false

    private var step: OnboardingStep { model.accounts.isEmpty ? .welcome : model.onboardingStep ?? .welcome }
    private var stepIndex: Int { OnboardingStep.allCases.firstIndex(of: step) ?? 0 }

    var body: some View {
        HStack(spacing: 0) {
            introductionRail
                .frame(width: 218)
            Divider().padding(.vertical, 20)
            VStack(alignment: .leading, spacing: 28) {
                content
                    .id(step)
                    .transition(.opacity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                footer
            }
            .padding(.leading, 44)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: 850, maxHeight: 550)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(DayfoldMotion.standard(reduceMotion), value: step)
        .navigationTitle("")
    }

    private var introductionRail: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable().interpolation(.high).frame(width: 80, height: 80)
                .accessibilityHidden(true)
                .padding(.leading, -8)
            Text("Dayfold").font(.system(size: 25, weight: .semibold, design: .rounded))
                .padding(.top, 12)
            Text("A little more room\nfor your day.")
                .font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(3)
                .padding(.top, 8)
            VStack(alignment: .leading, spacing: 22) {
                ForEach(Array(OnboardingStep.allCases.enumerated()), id: \.element) { index, item in
                    HStack(spacing: 10) {
                        ZStack {
                            Circle().fill(index <= stepIndex ? Color.dayfoldAccent.opacity(0.12) : Color.primary.opacity(0.04))
                            if index < stepIndex {
                                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                            } else {
                                Text("\(index + 1)").font(.system(size: 11, weight: .medium)).monospacedDigit()
                            }
                        }
                        .foregroundStyle(index <= stepIndex ? Color.dayfoldAccent : Color.secondary)
                        .frame(width: 24, height: 24)
                        Text(item.title).font(.system(size: 12, weight: index == stepIndex ? .semibold : .regular))
                            .foregroundStyle(index == stepIndex ? Color.primary : Color.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Step \(index + 1): \(item.title)\(index == stepIndex ? ", current step" : index < stepIndex ? ", completed" : "")")
                }
            }.padding(.top, 38)
            Spacer(minLength: 24)
            if !model.accounts.isEmpty, step != .ready {
                Button("Finish later") { model.finishOnboarding() }
                    .buttonStyle(.plain).foregroundStyle(Color.dayfoldAccent).font(.system(size: 11))
                    .disabled(model.isSavingCalendarSelection || model.isConnecting)
                    .padding(.bottom, 12)
            }
            Button("Your data, explained") { showingPrivacy.toggle() }
                .buttonStyle(.plain).foregroundStyle(Color.dayfoldAccent).font(.system(size: 11))
                .popover(isPresented: $showingPrivacy) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Your calendar stays yours.").font(.headline)
                        Text("Dayfold connects directly to Google and keeps a local calendar cache on this Mac. Google credentials are stored in Keychain.")
                        Text("A Dayfold account is optional. If you enable real-time updates in Settings, that service stores account and device information, routing IDs, and reminder times. The real-time service does not store event details.")
                        Text("If you use the assistant, your requests and relevant event titles and times are sent to OpenAI using your API key. Google credentials, guest lists, descriptions and meeting links are not read by its calendar tools.")
                        Text("Demo uses fictional calendars in a separate local store.").foregroundStyle(.secondary)
                    }.font(.system(size: 12)).padding(22).frame(width: 340)
                }
        }.padding(.vertical, 24).padding(.trailing, 24)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            welcome
        case .calendars:
            VStack(alignment: .leading, spacing: 20) {
                heading("Bring your days together.", subtitle: "Choose the calendars you’d like to keep in Dayfold. You can change these anytime in Settings.")
                CalendarSelectionView(model: model)
            }
        case .reminders:
            VStack(alignment: .leading, spacing: 24) {
                heading("A heads-up, when you need it.", subtitle: "Let your calendar give you a little breathing room before the next thing.")
                OnboardingRemindersView(model: model)
            }
        case .ready:
            VStack(alignment: .leading, spacing: 24) {
                heading("Your day, a little closer.", subtitle: "You’re ready to go. Here are two small ways to keep Dayfold within reach.")
                OnboardingCompanionView(model: model)
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 26) {
            heading("Your calendar. Your way.", subtitle: "Keep things hands-on, or get a little help planning. Choose how Dayfold opens for you.")
            ExperienceChoiceView(model: model)
            if model.isConnecting {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Finish signing in with Google in your browser.").font(.system(size: 12))
                        Button("Cancel sign-in") { model.auth.cancel() }.buttonStyle(.plain).foregroundStyle(Color.dayfoldAccent).font(.system(size: 11))
                    }
                }.accessibilityElement(children: .contain)
            } else if model.accounts.isEmpty {
                HStack(spacing: 6) {
                    Text("Just looking around?").foregroundStyle(.secondary)
                    Button("Explore Demo") { model.exploreDemo() }
                        .buttonStyle(.plain).foregroundStyle(Color.dayfoldAccent)
                }.font(.system(size: 12))
                Text("Try sample calendars. No sign-in needed.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, -19)
            } else if model.isDemo {
                Label("You’re exploring with fictional calendars.", systemImage: "sparkle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 16) {
            Divider()
            HStack(spacing: 12) {
                if stepIndex > 0 {
                    Button("Back") { model.moveOnboarding(to: OnboardingStep.allCases[stepIndex - 1]) }
                        .disabled(model.isSavingCalendarSelection)
                } else {
                    Text("About a minute to make it yours.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if step == .reminders {
                    Button("Not now") { model.moveOnboarding(to: .ready) }
                        .buttonStyle(.plain).foregroundStyle(Color.dayfoldAccent).font(.system(size: 12))
                }
                Button(primaryTitle, action: advance)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isConnecting || model.isSavingCalendarSelection)
            }
        }
    }

    private var primaryTitle: String {
        if step == .welcome && model.accounts.isEmpty { return model.isConnecting ? "Waiting for Google…" : "Connect Google Account" }
        return step == .ready ? (model.preferences.experienceMode == .assistant ? "Open Dayfold" : "Open Calendar") : "Continue"
    }

    private func advance() {
        switch step {
        case .welcome:
            if model.accounts.isEmpty { model.connect() }
            else { model.moveOnboarding(to: .calendars) }
        case .calendars: model.moveOnboarding(to: .reminders)
        case .reminders: model.moveOnboarding(to: .ready)
        case .ready: model.finishOnboarding()
        }
    }

    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 32, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                .lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }
    }

}
