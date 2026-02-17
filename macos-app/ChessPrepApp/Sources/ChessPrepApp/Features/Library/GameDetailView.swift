import SwiftUI

struct GameDetailView: View {
    let game: GameSummary?

    private let files = Array("abcdefgh")

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Game Detail")
                .font(Typography.sectionTitle)
                .foregroundStyle(Theme.textPrimary)

            if let game {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(game.white) vs \(game.black)")
                        .font(Typography.sectionTitle)

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text("Result")
                                .font(Typography.detailLabel)
                            Text(game.result)
                                .font(Typography.dataMono)
                        }
                        GridRow {
                            Text("Date")
                                .font(Typography.detailLabel)
                            Text(game.date)
                                .font(Typography.dataMono)
                        }
                        GridRow {
                            Text("ECO")
                                .font(Typography.detailLabel)
                            Text(game.eco)
                                .font(Typography.dataMono)
                        }
                        GridRow {
                            Text("Event")
                                .font(Typography.detailLabel)
                            Text(game.event)
                                .font(Typography.body)
                        }
                        GridRow {
                            Text("Site")
                                .font(Typography.detailLabel)
                            Text(game.site)
                                .font(Typography.body)
                        }
                    }
                }
                .panelCard()

                boardPlaceholder
                    .panelCard()
            } else {
                Text("Select a game from the table to inspect metadata and future replay tools.")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Spacer()
        }
        .foregroundStyle(Theme.textPrimary)
        .environment(\.colorScheme, .light)
        .padding(20)
        .background(Theme.background)
    }

    private var boardPlaceholder: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Board Preview (Scaffold)")
                .font(Typography.detailLabel)

            VStack(spacing: 0) {
                ForEach((0..<8).reversed(), id: \.self) { rank in
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { file in
                            let isDark = (rank + file).isMultiple(of: 2)
                            Rectangle()
                                .fill(isDark ? Theme.surfaceAlt : Theme.surface)
                                .frame(width: 24, height: 24)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 0)
                                        .stroke(Theme.border.opacity(0.25), lineWidth: 0.5)
                                )
                        }
                    }
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 10) {
                    ForEach(files, id: \.self) { file in
                        Text(String(file))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 24)
                    }
                }
                .padding(.leading, 1)
                .offset(y: 14)
            }
            .padding(.bottom, 14)
        }
    }
}
