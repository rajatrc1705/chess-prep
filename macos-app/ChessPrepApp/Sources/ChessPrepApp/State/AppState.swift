import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class AppState: ObservableObject {
    @Published var selectedSection: AppSection? = .library

    @Published var databasePath = "~/Documents/chess-prep.sqlite"
    @Published var pgnPath = ""
    @Published var selectedPgnPaths: [String] = []

    @Published var filter = GameFilter()
    @Published var games: [GameSummary] = []
    @Published var libraryPath: [LibraryRoute] = []
    @Published var selectedGameID: UUID?
    @Published var isLoadingGames = false
    @Published var libraryError: String?

    @Published var importState: ImportRunState = .idle
    @Published var importProgress = ImportProgress(total: 0, inserted: 0, skipped: 0, errors: 0)
    @Published var replayFens: [String] = []
    @Published var replaySans: [String] = []
    @Published var replayUcis: [String] = []
    @Published var currentPly = 0
    @Published var isLoadingReplay = false
    @Published var replayError: String?
    @Published var isReplayAutoPlaying = false
    @Published var enginePath = ""
    @Published var engineDepth = 18
    @Published var isAnalyzingEngine = false
    @Published var engineAnalysis: EngineAnalysis?
    @Published var engineError: String?

    private let gameRepository: any GameRepository
    private let importRepository: any ImportRepository
    private let replayRepository: any ReplayRepository
    private let engineRepository: any EngineRepository
    private var replayAutoPlayTask: Task<Void, Never>?

    init(
        gameRepository: any GameRepository = RustGameRepository(),
        importRepository: any ImportRepository = RustImportRepository(),
        replayRepository: any ReplayRepository = RustReplayRepository(),
        engineRepository: any EngineRepository = RustEngineRepository()
    ) {
        self.gameRepository = gameRepository
        self.importRepository = importRepository
        self.replayRepository = replayRepository
        self.engineRepository = engineRepository
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

    var currentFen: String? {
        guard replayFens.indices.contains(currentPly) else { return nil }
        return replayFens[currentPly]
    }

    var canStepBackward: Bool {
        currentPly > 0
    }

    var canStepForward: Bool {
        currentPly + 1 < replayFens.count
    }

    var maxPly: Int {
        max(replayFens.count - 1, 0)
    }

    var currentMoveSAN: String? {
        guard currentPly > 0 else { return nil }
        let index = currentPly - 1
        guard replaySans.indices.contains(index) else { return nil }
        return replaySans[index]
    }

    func loadGames() async {
        isLoadingGames = true
        libraryError = nil

        defer {
            isLoadingGames = false
        }

        do {
            let fetched = try await gameRepository.fetchGames(dbPath: databasePath, filter: filter)
            games = fetched

            if let selectedGameID, !games.contains(where: { $0.id == selectedGameID }) {
                self.selectedGameID = nil
                clearReplayState()
            }
        } catch {
            libraryError = error.localizedDescription
            games = []
            selectedGameID = nil
            libraryPath = []
            clearReplayState()
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
        importProgress = ImportProgress(total: 0, inserted: 0, skipped: 0, errors: 0)

        let pgnPaths = resolvedPgnPaths()
        guard !pgnPaths.isEmpty else {
            importState = .failure("At least one PGN file path is required.")
            return
        }

        let startedAt = Date()
        var total = 0
        var inserted = 0
        var skipped = 0
        var errors = 0

        do {
            for pgnPath in pgnPaths {
                let baseTotal = total
                let baseInserted = inserted
                let baseSkipped = skipped
                let baseErrors = errors

                let summary = try await importRepository.importPgn(
                    dbPath: databasePath,
                    pgnPath: pgnPath,
                    progress: { [weak self] nextProgress in
                        Task { @MainActor in
                            self?.importProgress = ImportProgress(
                                total: baseTotal + nextProgress.total,
                                inserted: baseInserted + nextProgress.inserted,
                                skipped: baseSkipped + nextProgress.skipped,
                                errors: baseErrors + nextProgress.errors
                            )
                        }
                    }
                )

                total += summary.total
                inserted += summary.inserted
                skipped += summary.skipped
                errors += summary.errors
                importProgress = ImportProgress(total: total, inserted: inserted, skipped: skipped, errors: errors)
            }

            let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
            importState = .success(
                ImportSummary(
                    total: total,
                    inserted: inserted,
                    skipped: skipped,
                    errors: errors,
                    durationMs: durationMs
                )
            )

            if selectedSection == .library {
                await loadGames()
            }
        } catch {
            importState = .failure(error.localizedDescription)
        }
    }

    func reloadReplayForCurrentSelection() {
        Task {
            await loadReplayForSelectedGame()
        }
    }

    func selectGameForPreview(databaseID: Int64) {
        selectGame(databaseID: databaseID)
        reloadReplayForCurrentSelection()
    }

    func openGameExplorer(gameID: Int64) {
        selectGame(databaseID: gameID)
        let route = LibraryRoute.gameExplorer(gameID)
        if libraryPath.last != route {
            libraryPath.append(route)
        }
    }

    func selectGame(databaseID: Int64) {
        guard let game = games.first(where: { $0.databaseID == databaseID }) else {
            selectedGameID = nil
            clearReplayState()
            return
        }

        if selectedGameID != game.id {
            selectedGameID = game.id
            clearReplayState()
        }
    }

    func stepBackward() {
        stopReplayAutoPlay()
        guard canStepBackward else { return }
        currentPly -= 1
        clearEngineOutput()
    }

    func stepForward() {
        stopReplayAutoPlay()
        guard canStepForward else { return }
        currentPly += 1
        clearEngineOutput()
    }

    func goToReplayStart() {
        stopReplayAutoPlay()
        currentPly = 0
        clearEngineOutput()
    }

    func goToReplayEnd() {
        stopReplayAutoPlay()
        currentPly = maxPly
        clearEngineOutput()
    }

    func setReplayPly(_ ply: Int) {
        stopReplayAutoPlay()
        currentPly = min(max(ply, 0), maxPly)
        clearEngineOutput()
    }

    func toggleReplayAutoPlay() {
        if isReplayAutoPlaying {
            stopReplayAutoPlay()
        } else {
            startReplayAutoPlay()
        }
    }

    func copyCurrentFenToPasteboard() {
        guard let currentFen else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(currentFen, forType: .string)
        #endif
    }

    func analyzeCurrentPosition() async {
        guard let fen = currentFen else {
            engineError = "No position selected."
            engineAnalysis = nil
            return
        }

        isAnalyzingEngine = true
        engineError = nil
        defer { isAnalyzingEngine = false }

        do {
            let analysis = try await engineRepository.analyzePosition(
                enginePath: enginePath,
                fen: fen,
                depth: engineDepth
            )
            engineAnalysis = analysis
        } catch {
            engineAnalysis = nil
            engineError = error.localizedDescription
        }
    }

    private func resolvedPgnPaths() -> [String] {
        if !selectedPgnPaths.isEmpty {
            return selectedPgnPaths
        }

        return pgnPath
            .split(whereSeparator: { $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func clearReplayState() {
        stopReplayAutoPlay()
        replayFens = []
        replaySans = []
        replayUcis = []
        currentPly = 0
        replayError = nil
        isLoadingReplay = false
        clearEngineOutput()
    }

    private func loadReplayForSelectedGame() async {
        guard let game = selectedGame else {
            clearReplayState()
            return
        }

        isLoadingReplay = true
        replayError = nil
        defer { isLoadingReplay = false }

        do {
            let replay = try await replayRepository.fetchReplay(
                dbPath: databasePath,
                gameID: game.databaseID
            )
            stopReplayAutoPlay()
            replayFens = replay.fens
            replaySans = replay.sans
            replayUcis = replay.ucis
            currentPly = 0
            clearEngineOutput()
        } catch {
            stopReplayAutoPlay()
            replayFens = []
            replaySans = []
            replayUcis = []
            currentPly = 0
            let message = error.localizedDescription
            if message.contains("MissingMovetext") || message.contains("GameNotFound") {
                replayError = nil
            } else {
                replayError = message
            }
            clearEngineOutput()
        }
    }

    private func startReplayAutoPlay() {
        guard replayFens.count > 1 else { return }
        if currentPly >= maxPly {
            currentPly = 0
        }

        replayAutoPlayTask?.cancel()
        isReplayAutoPlaying = true

        replayAutoPlayTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }

                if self.currentPly < self.maxPly {
                    self.currentPly += 1
                } else {
                    self.stopReplayAutoPlay()
                    return
                }
            }
        }
    }

    private func stopReplayAutoPlay() {
        replayAutoPlayTask?.cancel()
        replayAutoPlayTask = nil
        isReplayAutoPlaying = false
    }

    private func clearEngineOutput() {
        engineAnalysis = nil
        engineError = nil
        isAnalyzingEngine = false
    }

    deinit {
        replayAutoPlayTask?.cancel()
    }
}
