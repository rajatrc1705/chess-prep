import SwiftUI

enum Theme {
    static let background = Color(red: 0.97, green: 0.96, blue: 0.94)
    static let surface = Color.white
    static let surfaceAlt = Color(red: 0.94, green: 0.91, blue: 0.86)

    static let sidebarBackground = Color(red: 0.25, green: 0.17, blue: 0.11)
    static let sidebarFieldBackground = Color(red: 0.96, green: 0.95, blue: 0.93)

    static let border = Color(red: 0.52, green: 0.38, blue: 0.27)
    static let textPrimary = Color(red: 0.10, green: 0.08, blue: 0.07)
    static let textSecondary = Color(red: 0.32, green: 0.27, blue: 0.22)
    static let textOnBrown = Color(red: 0.99, green: 0.98, blue: 0.96)

    static let accent = Color(red: 0.40, green: 0.27, blue: 0.18)
    static let success = Color(red: 0.14, green: 0.48, blue: 0.19)
    static let error = Color(red: 0.72, green: 0.16, blue: 0.16)
}

struct PanelCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .foregroundStyle(Theme.textPrimary)
            .background(Theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Theme.border, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

extension View {
    func panelCard() -> some View {
        modifier(PanelCardModifier())
    }
}
