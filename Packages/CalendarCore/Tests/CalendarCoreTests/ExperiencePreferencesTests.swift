import Foundation
import Testing
@testable import CalendarCore

@Test func experiencePreferencesKeepExistingUsersInCalendar() throws {
    let decoder = JSONDecoder()
    let legacy = try decoder.decode(Preferences.self, from: Data(#"{"defaultDuration":45,"notifications":true}"#.utf8))
    #expect(legacy.experienceMode == .calendar)
    #expect(legacy.assistantModel == "gpt-5.4-mini")
    #expect(legacy.defaultDuration == 45 && legacy.notifications)

    let unknown = try decoder.decode(Preferences.self, from: Data(#"{"experienceMode":"future-mode","onboardingStep":"reminders"}"#.utf8))
    #expect(unknown.experienceMode == .calendar)
    #expect(unknown.onboardingStep == "reminders")
}

@Test func assistantExperienceChoicePersistsWithoutEnablingOtherFeatures() throws {
    var preferences = Preferences()
    preferences.experienceMode = .assistant
    preferences.onboardingStep = "calendars"
    preferences.assistantModel = "custom-model"
    let restored = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
    #expect(restored.experienceMode == .assistant)
    #expect(restored.onboardingStep == "calendars")
    #expect(restored.assistantModel == "custom-model")
    #expect(!restored.notifications && !restored.privateNotifications)
}
