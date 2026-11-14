import AppKit
import Combine
import CalendarPlatform
import CalendarCore
import UserNotifications

extension AppModel {
    func observeLifecycle() {
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.isSleeping = true; await self?.relay?.stop() } }.store(in: &lifecycleSubscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.isSleeping = false; await self?.handleClockOrActivation() } }.store(in: &lifecycleSubscriptions)
        for name in [NSApplication.didBecomeActiveNotification, NSNotification.Name.NSSystemClockDidChange, NSNotification.Name.NSSystemTimeZoneDidChange, NSNotification.Name.NSCalendarDayChanged] {
            NotificationCenter.default.publisher(for: name)
                .sink { [weak self] _ in Task { @MainActor in await self?.handleClockOrActivation() } }.store(in: &lifecycleSubscriptions)
        }
    }
    private func handleClockOrActivation() async {
        let previous = now; now = Date()
        if calendar.isDate(menuDate, inSameDayAs: previous), !calendar.isDate(previous, inSameDayAs: now) { menuDate = now }
        loginStatus = PlatformServices.loginStatus
        if let status = await notifications?.permission() {
            switch status {
            case .authorized, .provisional: notificationPermission = "Allowed"
            case .denied: notificationPermission = "Not allowed — enable Dayfold in System Settings"
            case .notDetermined: notificationPermission = "Not requested"
            @unknown default: notificationPermission = "Unavailable"
            }
        }
        await reload(); await resumeRelay(); await refresh()
    }
}
