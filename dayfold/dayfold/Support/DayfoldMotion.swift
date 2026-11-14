import SwiftUI

/// Short, interruptible motion for a frequently used desktop interface.
enum DayfoldMotion {
    static func standard(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .smooth(duration: 0.24)
    }

    static func quick(_ reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.12)
    }

    static func reveal(_ reduceMotion: Bool, from edge: Edge) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        switch edge {
        case .leading: return .offset(x: -12).combined(with: .opacity)
        case .trailing: return .offset(x: 12).combined(with: .opacity)
        case .top: return .offset(y: -8).combined(with: .opacity)
        case .bottom: return .offset(y: 8).combined(with: .opacity)
        }
    }
}

struct DayfoldPressStyle: ButtonStyle {
    @Environment(\.dayfoldReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.985 : 1)
            .animation(DayfoldMotion.quick(reduceMotion), value: configuration.isPressed)
    }
}

/// The debug launch option verifies reduced motion without changing macOS settings.
struct DayfoldMotionEnvironment: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool {
        #if DEBUG
        systemReduceMotion || ProcessInfo.processInfo.arguments.contains("--reduce-motion")
        #else
        systemReduceMotion
        #endif
    }

    func body(content: Content) -> some View {
        content.environment(\.dayfoldReduceMotion, reduceMotion)
    }
}

private struct DayfoldReducedMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var dayfoldReduceMotion: Bool {
        get { self[DayfoldReducedMotionKey.self] }
        set { self[DayfoldReducedMotionKey.self] = newValue }
    }
}
