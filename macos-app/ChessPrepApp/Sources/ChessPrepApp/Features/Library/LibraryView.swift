import SwiftUI

struct LibraryView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Game Library")
                        .font(Typography.title)
                        .foregroundStyle(Theme.textPrimary)

                    Text("\(state.games.count) games shown (\(state.activeDatabaseCount) DBs active)")
                        .font(Typography.body)
                        .foregroundStyle(Theme.textSecondary)
                }

                Spacer()

                Button("Refresh") {
                    state.reloadWithCurrentFilter()
                }
                .buttonStyle(.bordered)
            }

            if let libraryError = state.libraryError {
                Text(libraryError)
                    .font(Typography.body)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.error.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            ZStack {
                if state.games.isEmpty && !state.isLoadingGames {
                    VStack(spacing: 8) {
                        Text("No games match the current filters.")
                            .font(Typography.sectionTitle)
                            .foregroundStyle(Theme.textPrimary)
                        Text("Adjust filters or import more PGN files.")
                            .font(Typography.body)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Theme.border.opacity(0.35), lineWidth: 1)
                    )
                } else {
                    VStack(spacing: 0) {
                        headerRow
                        Divider()
                        List {
                            ForEach(state.games) { game in
                                row(for: game)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)
                            }
                        }
                        .listStyle(.plain)
                    }
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Theme.border.opacity(0.35), lineWidth: 1)
                    )
                }

                if state.isLoadingGames {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Loading games...")
                            .font(Typography.body)
                    }
                    .padding(12)
                    .panelCard()
                }
            }
        }
        .foregroundStyle(Theme.textPrimary)
        .tint(Theme.accent)
        .environment(\.colorScheme, .light)
        .padding(24)
        .background(Theme.background)
    }

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("White")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Black")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Result")
                .frame(width: 70, alignment: .leading)
            Text("Date")
                .frame(width: 92, alignment: .leading)
            Text("ECO")
                .frame(width: 52, alignment: .leading)
            Text("DB")
                .frame(width: 120, alignment: .leading)
            Text("Event")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Typography.detailLabel)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Theme.surfaceAlt.opacity(0.65))
    }

    private func row(for game: GameSummary) -> some View {
        let isSelected = state.selectedGameID == game.id

        return HStack(spacing: 8) {
            Text(game.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(game.black)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(game.result)
                .font(Typography.dataMono)
                .frame(width: 70, alignment: .leading)
            Text(game.date)
                .font(Typography.dataMono)
                .frame(width: 92, alignment: .leading)
            Text(game.eco)
                .font(Typography.dataMono)
                .frame(width: 52, alignment: .leading)
            Text(game.sourceDatabaseLabel)
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)
            Text(game.event)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(Typography.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Theme.accent.opacity(0.18) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Theme.accent.opacity(0.5) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            state.openGameExplorer(locator: game.locator)
        }
        .onTapGesture {
            state.selectGameForPreview(locator: game.locator)
        }
    }
}
