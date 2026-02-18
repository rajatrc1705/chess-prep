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

                    Text("\(state.games.count) games shown")
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
                Table(state.games, selection: $state.selectedGameID) {
                    TableColumn("White", value: \.white)
                    TableColumn("Black", value: \.black)
                    TableColumn("Result", value: \.result)
                    TableColumn("Date", value: \.date)
                    TableColumn("ECO", value: \.eco)
                    TableColumn("Event", value: \.event)
                }
                .onChange(of: state.selectedGameID) { _, _ in
                    state.reloadReplayForCurrentSelection()
                }
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.border.opacity(0.35), lineWidth: 1)
                )

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
}
