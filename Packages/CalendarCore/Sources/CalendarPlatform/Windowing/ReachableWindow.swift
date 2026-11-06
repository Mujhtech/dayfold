import SwiftUI
import AppKit

public enum WindowPlacementPolicy {
    public static func reachable(_ frame: CGRect, screens: [CGRect]) -> CGRect {
        guard let main = screens.first else { return frame }
        let title = CGRect(x: frame.minX, y: frame.maxY - 36, width: frame.width, height: 36)
        if screens.contains(where: { title.intersection($0).width >= min(frame.width, 160) && title.intersection($0).height >= 24 }) { return frame }
        let size = CGSize(width: min(frame.width, main.width), height: min(frame.height, main.height))
        return CGRect(x: main.midX - size.width / 2, y: main.midY - size.height / 2, width: size.width, height: size.height)
    }
}

/// SwiftUI owns the scene; this view only handles macOS 14 frame restoration.
public struct ReachableWindow: NSViewRepresentable {
    private let identifier: String
    private let hideInitially: @MainActor () -> Bool
    public init(identifier: String, hideInitially: @escaping @MainActor () -> Bool) {
        self.identifier = identifier; self.hideInitially = hideInitially
    }
    public func makeNSView(context: Context) -> NSView { FrameObserver(identifier: identifier, hideInitially: hideInitially) }
    public func updateNSView(_ nsView: NSView, context: Context) {}

    @MainActor private final class FrameObserver: NSView {
        let name: String
        let hideInitially: @MainActor () -> Bool
        weak var configured: NSWindow?
        init(identifier: String, hideInitially: @escaping @MainActor () -> Bool) {
            name = identifier; self.hideInitially = hideInitially
            super.init(frame: .zero)
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        }
        required init?(coder: NSCoder) { fatalError("FrameObserver is created in code.") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window !== configured else { return }
            configured = window
            window.identifier = NSUserInterfaceItemIdentifier(name)
            window.setFrameAutosaveName(name)
            window.setFrameUsingName(name)
            screenChanged()
            Task { @MainActor [weak self, weak window] in
                if self?.hideInitially() == true { window?.orderOut(nil) }
            }
        }
        @objc private func screenChanged() {
            guard let window else { return }
            let visible = WindowPlacementPolicy.reachable(window.frame, screens: NSScreen.screens.map(\.visibleFrame))
            if visible != window.frame { window.setFrame(visible, display: true) }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
