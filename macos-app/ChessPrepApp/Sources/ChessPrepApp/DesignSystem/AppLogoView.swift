import SwiftUI

struct AppLogoView: View {
    let size: CGFloat
    let titleColor: Color
    let subtitleColor: Color
    let badgeDark: Color
    let badgeLight: Color
    let iconColor: Color
    let subtitle: String?

    init(
        size: CGFloat = 36,
        titleColor: Color = Theme.textPrimary,
        subtitleColor: Color = Theme.textSecondary,
        badgeDark: Color = Theme.accent,
        badgeLight: Color = Theme.surfaceAlt,
        iconColor: Color = .white,
        subtitle: String? = "Study faster"
    ) {
        self.size = size
        self.titleColor = titleColor
        self.subtitleColor = subtitleColor
        self.badgeDark = badgeDark
        self.badgeLight = badgeLight
        self.iconColor = iconColor
        self.subtitle = subtitle
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [badgeLight, badgeDark],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: "chess.knight.fill")
                    .font(.system(size: size * 0.54, weight: .black, design: .rounded))
                    .foregroundStyle(iconColor)
                    .shadow(color: .black.opacity(0.25), radius: 1, x: 0, y: 1)
            }
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .stroke(.black.opacity(0.16), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 1) {
                Text("ChessPrep")
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundStyle(titleColor)

                if let subtitle {
                    Text(subtitle)
                        .font(Typography.detailLabel)
                        .foregroundStyle(subtitleColor)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("ChessPrep")
    }
}
