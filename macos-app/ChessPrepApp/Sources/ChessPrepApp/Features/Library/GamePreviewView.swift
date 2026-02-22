import SwiftUI

struct GamePreviewView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Game Preview")
                .font(Typography.sectionTitle)
                .foregroundStyle(Theme.textPrimary)

            if let game = state.selectedGame {
                selectedPreview(game: game)
            } else {
                emptyPreview
            }

            Spacer()
        }
        .padding(20)
        .background(Theme.background)
    }

    private var emptyPreview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Single-click a row to preview. Double-click to open Game Explorer.")
                .font(Typography.body)
                .foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 8) {
                previewChip(label: "Games shown", value: "\(state.games.count)")
                previewChip(label: "Result filter", value: state.filter.result.rawValue)
                previewChip(label: "Search", value: normalized(state.filter.searchText))
                previewChip(label: "ECO", value: normalized(state.filter.eco))
                previewChip(label: "Event/Site", value: normalized(state.filter.eventOrSite))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border.opacity(0.35), lineWidth: 1)
        )
    }

    private func selectedPreview(game: GameSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(game.white) vs \(game.black)")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Theme.textPrimary)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
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
                            .lineLimit(1)
                    }
                    GridRow {
                        Text("Site")
                            .font(Typography.detailLabel)
                        Text(game.site)
                            .font(Typography.body)
                            .lineLimit(1)
                    }
                    GridRow {
                        Text("Database")
                            .font(Typography.detailLabel)
                        Text(game.sourceDatabaseLabel)
                            .font(Typography.body)
                            .lineLimit(1)
                    }
                }
            }

            if state.isLoadingReplay {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading preview...")
                        .font(Typography.body)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if let replayError = state.replayError {
                Text(replayError)
                    .font(Typography.body)
                    .foregroundStyle(Theme.error)
            } else if let fen = state.currentFen ?? state.replayFens.first {
                ChessBoardView(
                    fen: fen,
                    whiteAtBottom: true,
                    highlightedSquares: [],
                    lastMove: nil,
                    showCoordinates: false,
                    cellSize: 24
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("No preview board available yet.")
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
            }

            Button("Open Game Explorer") {
                state.openGameExplorer(game: game)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border.opacity(0.35), lineWidth: 1)
        )
    }

    private func normalized(_ text: String) -> String {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Any" : value
    }

    private func previewChip(label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Typography.detailLabel)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(Typography.dataMono)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.surfaceAlt.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
