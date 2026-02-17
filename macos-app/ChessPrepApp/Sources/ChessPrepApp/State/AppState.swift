import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var selectedSection: AppSection? = .library

    @Published var databasePath = "~/Documents/chess-prep.sqlite"
    @Published var pgnPath = ""

    @Published var filter = GameFilter()
    @Published var games: [GameSummary] = []
    @Published var selectedGameID: UUID?
    @Published var isLoadingGames = false
    @Published var libraryError: String?

    @Published var importState: ImportRunState = .idle
    @Published var importProgress = ImportProgress(total: 0, inserted: 0, skipped: 0)

    private let gameRepository: any GameRepository
    private let importRepository: any ImportRepository

    init(
        gameRepository: any GameRepository = MockGameRepository(),
        importRepository: any ImportRepository = MockImportRepository()
    ) {
        self.gameRepository = gameRepository
        self.importRepository = importRepository
    }

    var selectedGame: GameSummary? {
        guard let selectedGameID else { return nil }
        return games.first(where: { $0.id == selectedGameID })
    }

    var isImportRunning: Bool {
        if case .running = importState {
            return true
        }
        return false
    }

    func loadGames() async {
        isLoadingGames = true
        libraryError = nil

        defer {
            isLoadingGames = false
        }

        do {
            let fetched = try await gameRepository.fetchGames(filter: filter)
            games = fetched

            if let selectedGameID, !games.contains(where: { $0.id == selectedGameID }) {
                self.selectedGameID = games.first?.id
            } else if selectedGameID == nil {
                selectedGameID = games.first?.id
            }
        } catch {
            libraryError = error.localizedDescription
            games = []
            selectedGameID = nil
        }
    }

    func reloadWithCurrentFilter() {
        Task {
            await loadGames()
        }
    }

    func resetFilters() {
        filter = GameFilter()
        reloadWithCurrentFilter()
    }

    func startImport() async {
        importState = .running
        importProgress = ImportProgress(total: 0, inserted: 0, skipped: 0)

        do {
            let summary = try await importRepository.importPgn(
                dbPath: databasePath,
                pgnPath: pgnPath,
                progress: { [weak self] nextProgress in
                    Task { @MainActor in
                        self?.importProgress = nextProgress
                    }
                }
            )

            importProgress = ImportProgress(
                total: summary.total,
                inserted: summary.inserted,
                skipped: summary.skipped
            )
            importState = .success(summary)

            if selectedSection == .library {
                await loadGames()
            }
        } catch {
            importState = .failure(error.localizedDescription)
        }
    }
}
