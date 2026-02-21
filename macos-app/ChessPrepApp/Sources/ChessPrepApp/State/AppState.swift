import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class AppState: ObservableObject {
    @Published var selectedSection: AppSection? = .library

    @Published var pgnPath = ""
    @Published var selectedPgnPaths: [String] = []

    @Published var workspaceDatabases: [WorkspaceDatabase] = []
    @Published var selectedImportDatabaseID: UUID?
    @Published var workspaceError: String?

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
    private let workspaceStore: WorkspaceStore
    private var replayAutoPlayTask: Task<Void, Never>?

    init(
        gameRepository: any GameRepository = RustGameRepository(),
        importRepository: any ImportRepository = RustImportRepository(),
        replayRepository: any ReplayRepository = RustReplayRepository(),
        engineRepository: any EngineRepository = RustEngineRepository(),
        workspaceStore: WorkspaceStore = WorkspaceStore()
    ) {
        self.gameRepository = gameRepository
        self.importRepository = importRepository
        self.replayRepository = replayRepository
        self.engineRepository = engineRepository
        self.workspaceStore = workspaceStore
        loadWorkspaceDatabases()
    }

    var selectedGame: GameSummary? {
        guard let selectedGameID else { return nil }
        return games.first(where: { $0.id == selectedGameID })
    }

    var selectedImportDatabase: WorkspaceDatabase? {
        guard let selectedImportDatabaseID else { return nil }
        return workspaceDatabases.first(where: { $0.id == selectedImportDatabaseID })
    }

    var activeDatabaseCount: Int {
        workspaceDatabases.filter(\.isActive).count
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
        refreshDatabaseAvailability()

        defer {
            isLoadingGames = false
        }

        do {
            let fetched = try await gameRepository.fetchGames(databases: workspaceDatabases, filter: filter)
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
        workspaceError = nil

        let pgnPaths = resolvedPgnPaths()
        guard !pgnPaths.isEmpty else {
            importState = .failure("At least one PGN file path is required.")
            return
        }

        refreshDatabaseAvailability()
        guard let target = selectedImportDatabase else {
            importState = .failure("Select an import target database.")
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
                    dbPath: target.path,
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

            refreshDatabaseAvailability()
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

    func selectGameForPreview(locator: GameLocator) {
        selectGame(locator: locator)
        reloadReplayForCurrentSelection()
    }

    func openGameExplorer(locator: GameLocator) {
        selectGame(locator: locator)
        let route = LibraryRoute.gameExplorer(locator)
        if libraryPath.last != route {
            libraryPath.append(route)
        }
    }

    func openGameExplorer(game: GameSummary) {
        openGameExplorer(locator: game.locator)
    }

    func selectGame(locator: GameLocator) {
        guard let game = games.first(where: {
            $0.databaseID == locator.databaseID && $0.sourceDatabasePath == locator.sourceDatabasePath
        }) else {
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

    func registerDatabase(path: String, label: String? = nil) {
        workspaceError = nil
        let normalizedPath = RustBridge.expandTilde(path).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            workspaceError = "Database path is required."
            return
        }

        if let existing = workspaceDatabases.first(where: { normalizePath($0.path) == normalizePath(normalizedPath) }) {
            selectedImportDatabaseID = existing.id
            return
        }

        let now = Date()
        var displayLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if displayLabel.isEmpty {
            let fileName = URL(fileURLWithPath: normalizedPath).deletingPathExtension().lastPathComponent
            displayLabel = fileName.isEmpty ? "Database \(workspaceDatabases.count + 1)" : fileName
        }

        let entry = WorkspaceDatabase(
            id: UUID(),
            label: displayLabel,
            path: normalizedPath,
            isActive: true,
            isAvailable: FileManager.default.fileExists(atPath: normalizedPath),
            createdAt: now,
            updatedAt: now
        )

        workspaceDatabases.append(entry)
        selectedImportDatabaseID = entry.id
        saveWorkspaceDatabases()
    }

    func removeDatabase(id: UUID) {
        workspaceDatabases.removeAll { $0.id == id }
        if selectedImportDatabaseID == id {
            selectedImportDatabaseID = workspaceDatabases.first?.id
        }

        if let selectedGame, !workspaceDatabases.contains(where: { normalizePath($0.path) == normalizePath(selectedGame.sourceDatabasePath) }) {
            selectedGameID = nil
            clearReplayState()
        }

        saveWorkspaceDatabases()
        reloadWithCurrentFilter()
    }

    func setDatabaseActive(id: UUID, isActive: Bool) {
        guard let index = workspaceDatabases.firstIndex(where: { $0.id == id }) else {
            return
        }
        workspaceDatabases[index].isActive = isActive
        workspaceDatabases[index].updatedAt = Date()
        saveWorkspaceDatabases()
        reloadWithCurrentFilter()
    }

    func renameDatabase(id: UUID, label: String) {
        guard let index = workspaceDatabases.firstIndex(where: { $0.id == id }) else {
            return
        }
        let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanLabel.isEmpty else { return }
        workspaceDatabases[index].label = cleanLabel
        workspaceDatabases[index].updatedAt = Date()
        saveWorkspaceDatabases()
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
                dbPath: game.sourceDatabasePath,
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

    private func loadWorkspaceDatabases() {
        let records = workspaceStore.load()
        if records.isEmpty {
            let now = Date()
            let defaultPath = RustBridge.expandTilde("~/Documents/chess-prep.sqlite")
            workspaceDatabases = [
                WorkspaceDatabase(
                    id: UUID(),
                    label: "Main DB",
                    path: defaultPath,
                    isActive: true,
                    isAvailable: FileManager.default.fileExists(atPath: defaultPath),
                    createdAt: now,
                    updatedAt: now
                ),
            ]
            selectedImportDatabaseID = workspaceDatabases.first?.id
            saveWorkspaceDatabases()
            return
        }

        workspaceDatabases = records.map { record in
            WorkspaceDatabase(
                id: record.id,
                label: record.label,
                path: record.path,
                isActive: record.isActive,
                isAvailable: FileManager.default.fileExists(atPath: record.path),
                createdAt: record.createdAt,
                updatedAt: record.updatedAt
            )
        }
        selectedImportDatabaseID = workspaceDatabases.first?.id
    }

    private func saveWorkspaceDatabases() {
        let records = workspaceDatabases.map { database in
            WorkspaceDatabaseRecord(
                id: database.id,
                label: database.label,
                path: database.path,
                isActive: database.isActive,
                createdAt: database.createdAt,
                updatedAt: database.updatedAt
            )
        }
        do {
            try workspaceStore.save(records)
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    private func refreshDatabaseAvailability() {
        workspaceDatabases = workspaceDatabases.map { database in
            var updated = database
            let normalizedPath = RustBridge.expandTilde(database.path)
            updated.isAvailable = FileManager.default.fileExists(atPath: normalizedPath)
            updated.path = normalizedPath
            return updated
        }
    }

    private func normalizePath(_ path: String) -> String {
        RustBridge.expandTilde(path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    deinit {
        replayAutoPlayTask?.cancel()
    }
}
