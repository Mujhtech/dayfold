import SwiftUI
import CalendarCore
import CalendarPlatform
import AppKit
import Carbon

@main
struct DayfoldApp: App {
    @NSApplicationDelegateAdaptor(DayfoldDelegate.self) private var delegate
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup("Dayfold", id: "calendar") {
            CalendarWindow(model: model)
                .frame(minWidth: 980, minHeight: 660)
                .background(ReachableWindow(identifier: "dayfold-calendar", hideInitially: { DayfoldDelegate.launchedAtLogin }))
                .preferredColorScheme(model.preferences.appearance == "light" ? .light : model.preferences.appearance == "dark" ? .dark : nil)
        }
        .defaultSize(width: 1320, height: 860)
        .commands { DayfoldCommands(model: model) }
        Settings { SettingsView(model: model).frame(width: 700, height: 620) }
        MenuBarExtra { MenuBarView(model: model) } label: { Label(model.menuTitle, systemImage: "calendar") }
            .menuBarExtraStyle(.window)
        Window("Quick entry", id: "quick-entry") { QuickEntryView(model: model).frame(width: 540).padding(24) }
            .windowResizability(.contentSize)
    }
}

@MainActor final class DayfoldDelegate: NSObject, NSApplicationDelegate {
    static weak var currentModel: AppModel?
    static var launchedAtLogin = false
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let login = NSAppleEventManager.shared().currentAppleEvent?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        Self.launchedAtLogin = login
        if login { for window in NSApp.windows { window.orderOut(nil) } }
        else { NSApp.activate(ignoringOtherApps: true) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating, let model = Self.currentModel else { return .terminateNow }
        terminating = true
        Task {
            do { try await model.flushLocalDrafts(); sender.reply(toApplicationShouldTerminate: true) }
            catch {
                terminating = false
                model.errorMessage = "Dayfold could not save your draft before quitting. Your text is still open. " + error.localizedDescription
                model.openCalendar?(); sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.launchedAtLogin = false
        if !flag, let window = sender.windows.first(where: { $0.identifier?.rawValue == "dayfold-calendar" }) { window.makeKeyAndOrderFront(nil) }
        return true
    }
}

struct DayfoldCommands: Commands {
    @Bindable var model: AppModel
    var body: some Commands {
        CommandGroup(replacing: .newItem) { Button("New Event") { model.newDraft(); model.openCalendar?() }.keyboardShortcut("n") }
        CommandGroup(after: .textEditing) { Button("Search Calendar") { model.page = .calendar; model.mode = .agenda; model.openCalendar?(); NotificationCenter.default.post(name: .init("DayfoldFocusSearch"), object: nil) }.keyboardShortcut("f") }
        CommandMenu("Calendar") {
            Button("Today") { model.today() }.keyboardShortcut("t").disabled(model.isTextEditing)
            Button("Previous") { model.navigate(-1) }.keyboardShortcut(.leftArrow).disabled(model.isTextEditing)
            Button("Next") { model.navigate(1) }.keyboardShortcut(.rightArrow).disabled(model.isTextEditing)
            Divider()
            ForEach(Array(CalendarViewMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.rawValue) { model.mode = mode; model.page = .calendar; model.dateChanged() }.keyboardShortcut(KeyEquivalent(Character(String(index + 1)))).disabled(model.isTextEditing)
            }
            Divider()
            Button("Refresh Calendars") { Task { await model.refresh() } }.keyboardShortcut("r")
            Button("Quick Entry") { model.openQuickEntry?() }
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") {
                if model.isTextEditing { NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil) }
                else { model.undoCalendarChange() }
            }.keyboardShortcut("z").disabled(!model.isTextEditing && model.undoCandidate == nil)
            Button("Redo") {
                if model.isTextEditing { NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil) }
                else { model.redoCalendarChange() }
            }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.isTextEditing && model.redoCandidate == nil)
        }
        CommandGroup(replacing: .help) {
            Button("Dayfold Help") { model.errorMessage = "Dayfold connects directly to Google and keeps a local cache. Closing the calendar leaves the menu bar companion running. Cmd-Q stops synchronization; previously scheduled reminders may still appear. Dates not downloaded are unavailable offline. Use Settings → Advanced to export pending changes. Demo data is stored separately and never sent to Google." }
        }
    }
}
extension AppModel { var isTextEditing: Bool { NSApp.keyWindow?.firstResponder is NSTextView } }
