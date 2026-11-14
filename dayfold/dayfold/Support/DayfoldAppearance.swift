import SwiftUI

extension Color {
    /// Use the named brand asset so Dayfold's controls and custom selections agree.
    static let dayfoldAccent = Color("AccentColor")
}

/// Apply shared appearance defaults at every scene and sheet root. SwiftUI
/// presentations own their color-scheme preference independently of AppKit.
struct DayfoldAppearance: ViewModifier {
    let preference: String

    private var scheme: ColorScheme? {
        switch preference {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    func body(content: Content) -> some View {
        content
            .preferredColorScheme(scheme)
            .tint(.dayfoldAccent)
            .scrollIndicators(.never)
    }
}
