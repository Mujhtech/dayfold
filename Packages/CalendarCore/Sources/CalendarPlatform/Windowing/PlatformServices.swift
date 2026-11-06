import AppKit
import CalendarCore
import KeyboardShortcuts
import ServiceManagement
import Darwin

public final class ProcessOwnership: @unchecked Sendable {
    private let descriptor: Int32
    public init(path: String) throws {
        descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CalendarError.disk("Could not open the calendar ownership lock.") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw CalendarError.unavailable("Dayfold is already using this data. Open the existing app from the Dock.") }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}
extension KeyboardShortcuts.Name {
    public static let dayfoldQuickEntry = Self("dayfoldQuickEntry", initial: .init(.space, modifiers: [.control, .option]))
}
@MainActor public enum PlatformServices {
    public static func registerQuickEntry(_ action: @escaping @MainActor () -> Void) { KeyboardShortcuts.onKeyUp(for: .dayfoldQuickEntry, action: action) }
    public static var loginStatus: String {
        switch SMAppService.mainApp.status { case .enabled: "Enabled"; case .notRegistered: "Off"; case .requiresApproval: "Approval required in System Settings"; case .notFound: "Unavailable"; @unknown default: "Unknown" }
    }
    public static func setLogin(_ enabled: Bool) throws { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
    public static func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }
}
