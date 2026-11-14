import AppKit
import SwiftUI
import Testing
import CalendarPlatform

/// These windows remain offscreen; the test changes only its own process's
/// appearance and does not change macOS or the running Dayfold application's theme.
@Test @MainActor func appearanceChangesReachExistingAndNewWindows() throws {
    let application = NSApplication.shared
    application.finishLaunching()
    let original = application.appearance
    defer { application.appearance = original }

    PlatformServices.setAppearance("system")
    let system = try #require(application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]))

    func makeWindow(panel: Bool = false, swiftUI: Bool = true) -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let window: NSWindow = panel
            ? NSPanel(contentRect: frame, styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
            : NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = swiftUI ? NSHostingView(rootView: Text("Appearance inheritance")) : NSView()
        return window
    }

    // Exercise the native window and panel hosting used by the main app,
    // Settings, Quick Entry, and the window-style companion.
    let existing = [makeWindow(swiftUI: false), makeWindow(), makeWindow(panel: true)]
    defer { existing.forEach { $0.close() } }

    let selections: [(String, NSAppearance.Name)] = [
        ("light", .aqua), ("dark", .darkAqua), ("system", system),
        ("light", .aqua), ("system", system), ("dark", .darkAqua)
    ]
    for (selection, expected) in selections {
        PlatformServices.setAppearance(selection)
        #expect(application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
        if selection == "system" { #expect(application.appearance == nil) }

        // Allow bounded event-loop delivery of AppKit appearance notifications,
        // without persistence, close/reopen, or activation.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        for window in existing {
            #expect(window.appearance == nil)
            #expect(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected,
                    "\(selection), content: \(String(describing: type(of: window.contentView!))), window override: \(String(describing: window.appearance?.name))")
            #expect(window.contentView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
        }

        let newlyOpened = makeWindow(panel: true)
        #expect(newlyOpened.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
        #expect(newlyOpened.contentView?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
        newlyOpened.close()
    }
}
