import Foundation
import CalendarCore

enum OnboardingStep: String, CaseIterable, Identifiable {
    case welcome, calendars, reminders, ready

    var id: String { rawValue }
    var title: String {
        switch self {
        case .welcome: "Welcome"
        case .calendars: "Your calendars"
        case .reminders: "A gentle reminder"
        case .ready: "Make yourself at home"
        }
    }
}

extension AppModel {
    var isShowingOnboarding: Bool {
        !isLoading && fatalMessage == nil && (accounts.isEmpty || onboardingStep != nil)
    }

    func showIntroduction() {
        guard !isLoading, editingDraft == nil, !isConnecting, !isSavingCalendarSelection else { return }
        selectedEvent = nil
        showAccountSetup = false
        moveOnboarding(to: .welcome)
        openCalendar?()
    }

    func moveOnboarding(to step: OnboardingStep?) {
        onboardingStep = step
        preferences.onboardingStep = step?.rawValue
        // Capture this store and snapshot before another window or a store switch
        // can change the model. Completion never affects the other store.
        let repository = repository, snapshot = preferences, generation = sessionGeneration
        Task {
            do { try await repository?.setPreferences(snapshot) }
            catch {
                guard generation == sessionGeneration else { return }
                errorMessage = "Could not save setup progress. " + error.localizedDescription
            }
        }
    }

    func finishOnboarding() {
        guard !accounts.isEmpty else { return }
        moveOnboarding(to: nil)
        page = preferredPage
        Task { await refresh() }
    }

    func exploreDemo() {
        let experience = preferences.experienceMode
        Task {
            await loadStore(demo: true)
            guard isDemo, fatalMessage == nil else { return }
            preferences.experienceMode = experience
            page = preferredPage
            savePreferences()
        }
    }
}
