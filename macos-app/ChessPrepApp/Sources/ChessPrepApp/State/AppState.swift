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
    @Published var analysisNodesByID: [UUID: AnalysisNode] = [:]
    @Published var analysisNodeIDByPly: [UUID] = []
    @Published var analysisRootNodeID: UUID?
    @Published var currentAnalysisNodeID: UUID?
    @Published var analysisMoveInput = ""
    @Published var analysisError: String?
    @Published var enginePath = ""
    @Published var engineDepth = 18
    @Published var isAnalyzingEngine = false
    @Published var engineAnalysis: EngineAnalysis?
    @Published var engineError: String?

    private let gameRepository: any GameRepository
    private let importRepository: any ImportRepository
    private let replayRepository: any ReplayRepository
    private let engineRepository: any EngineRepository
    private let analysisRepository: any AnalysisRepository
    private let workspaceStore: WorkspaceStore
    private var replayAutoPlayTask: Task<Void, Never>?

    init(
        gameRepository: any GameRepository = RustGameRepository(),
        importRepository: any ImportRepository = RustImportRepository(),
        replayRepository: any ReplayRepository = RustReplayRepository(),
        engineRepository: any EngineRepository = RustEngineRepository(),
        analysisRepository: any AnalysisRepository = RustAnalysisRepository(),
        workspaceStore: WorkspaceStore = WorkspaceStore()
    ) {
        self.gameRepository = gameRepository
        self.importRepository = importRepository
        self.replayRepository = replayRepository
        self.engineRepository = engineRepository
        self.analysisRepository = analysisRepository
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
        guard let currentAnalysisNodeID else {
            return currentPly > 0
        }

        if let mainlinePly = analysisNodeIDByPly.firstIndex(of: currentAnalysisNodeID) {
            return mainlinePly > 0
        }

        return analysisNodesByID[currentAnalysisNodeID]?.parentID != nil
    }

    var canStepForward: Bool {
        guard let currentAnalysisNodeID else {
            return currentPly + 1 < replayFens.count
        }

        if let mainlinePly = analysisNodeIDByPly.firstIndex(of: currentAnalysisNodeID) {
            return analysisNodeIDByPly.indices.contains(mainlinePly + 1)
        }

        guard let node = analysisNodesByID[currentAnalysisNodeID] else { return false }
        return !node.children.isEmpty
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

    var currentAnalysisNode: AnalysisNode? {
        guard let currentAnalysisNodeID else { return nil }
        return analysisNodesByID[currentAnalysisNodeID]
    }

    var currentAnalysisFen: String? {
        currentAnalysisNode?.fen
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
        guard let currentAnalysisNodeID else {
            guard canStepBackward else { return }
            setReplayPly(currentPly - 1)
            return
        }

        if let mainlinePly = analysisNodeIDByPly.firstIndex(of: currentAnalysisNodeID) {
            guard mainlinePly > 0 else { return }
            setReplayPly(mainlinePly - 1)
            return
        }

        guard let parentID = analysisNodesByID[currentAnalysisNodeID]?.parentID else { return }
        selectAnalysisStepNode(parentID)
    }

    func stepForward() {
        stopReplayAutoPlay()
        guard let currentAnalysisNodeID else {
            guard canStepForward else { return }
            setReplayPly(currentPly + 1)
            return
        }

        if let mainlinePly = analysisNodeIDByPly.firstIndex(of: currentAnalysisNodeID) {
            let nextPly = mainlinePly + 1
            guard analysisNodeIDByPly.indices.contains(nextPly) else { return }
            setReplayPly(nextPly)
            return
        }

        guard let nextID = analysisNodesByID[currentAnalysisNodeID]?.children.first else { return }
        selectAnalysisStepNode(nextID)
    }

    func goToReplayStart() {
        stopReplayAutoPlay()
        setReplayPly(0)
    }

    func goToReplayEnd() {
        stopReplayAutoPlay()
        setReplayPly(maxPly)
    }

    func setReplayPly(_ ply: Int) {
        stopReplayAutoPlay()
        currentPly = min(max(ply, 0), maxPly)
        syncAnalysisSelectionToCurrentPly(clearError: true)
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
        guard let fen = currentAnalysisFen ?? currentFen else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fen, forType: .string)
        #endif
    }

    func analyzeCurrentPosition() async {
        let fenToAnalyze = currentAnalysisFen ?? currentFen
        guard let fen = fenToAnalyze else {
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

    func rebuildAnalysisTreeFromReplay() {
        clearAnalysisState()

        guard let rootFen = replayFens.first else {
            return
        }

        let rootID = UUID()
        let root = AnalysisNode(
            id: rootID,
            parentID: nil,
            san: nil,
            uci: nil,
            fen: rootFen,
            comment: "",
            nags: [],
            children: []
        )
        analysisNodesByID[rootID] = root
        analysisNodeIDByPly.append(rootID)

        var parentID = rootID
        for index in replaySans.indices {
            let nextFenIndex = index + 1
            guard replayFens.indices.contains(nextFenIndex) else {
                break
            }

            let nodeID = UUID()
            let node = AnalysisNode(
                id: nodeID,
                parentID: parentID,
                san: replaySans[index],
                uci: replayUcis.indices.contains(index) ? replayUcis[index] : nil,
                fen: replayFens[nextFenIndex],
                comment: "",
                nags: [],
                children: []
            )
            analysisNodesByID[nodeID] = node
            analysisNodeIDByPly.append(nodeID)
            appendAnalysisChild(parentID: parentID, childID: nodeID)
            parentID = nodeID
        }

        analysisRootNodeID = rootID
        syncAnalysisSelectionToCurrentPly()
    }

    func selectAnalysisNode(id: UUID) {
        guard analysisNodesByID[id] != nil else { return }
        currentAnalysisNodeID = id
        analysisError = nil
        clearEngineOutput()
    }

    func applyAnalysisMoveFromInput() async {
        let input = analysisMoveInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            analysisError = "UCI move is required."
            return
        }
        await addAnalysisMove(uci: input)
        if analysisError == nil {
            analysisMoveInput = ""
        }
    }

    func addAnalysisMove(uci: String) async {
        let normalizedUci = uci.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUci.isEmpty else {
            analysisError = "UCI move is required."
            return
        }
        guard let currentNodeID = currentAnalysisNodeID,
              let currentNode = analysisNodesByID[currentNodeID] else {
            analysisError = "No active analysis node."
            return
        }

        do {
            if let existingChildID = currentNode.children.first(where: { childID in
                guard let childUci = analysisNodesByID[childID]?.uci else { return false }
                return childUci.caseInsensitiveCompare(normalizedUci) == .orderedSame
            }) {
                currentAnalysisNodeID = existingChildID
                analysisError = nil
                clearEngineOutput()
                return
            }

            let applied = try await analysisRepository.applyMove(fen: currentNode.fen, uci: normalizedUci)
            let childID = UUID()
            let child = AnalysisNode(
                id: childID,
                parentID: currentNodeID,
                san: applied.san,
                uci: applied.uci,
                fen: applied.fen,
                comment: "",
                nags: [],
                children: []
            )
            analysisNodesByID[childID] = child
            appendAnalysisChild(parentID: currentNodeID, childID: childID)
            currentAnalysisNodeID = childID
            analysisError = nil
            clearEngineOutput()
        } catch {
            analysisError = error.localizedDescription
        }
    }

    func deleteAnalysisNode(id: UUID) {
        guard analysisNodesByID[id] != nil else { return }
        guard id != analysisRootNodeID else {
            analysisError = "Cannot delete the analysis root."
            return
        }
        guard !analysisNodeIDByPly.contains(id) else {
            analysisError = "Replay mainline moves cannot be deleted."
            return
        }

        let removedNodeIDs = collectAnalysisSubtreeIDs(startingAt: id)
        guard !removedNodeIDs.isEmpty else { return }

        let parentID = analysisNodesByID[id]?.parentID
        for removedID in removedNodeIDs {
            analysisNodesByID.removeValue(forKey: removedID)
        }

        if let parentID, var parent = analysisNodesByID[parentID] {
            parent.children.removeAll { removedNodeIDs.contains($0) }
            analysisNodesByID[parentID] = parent
        }

        if let currentID = currentAnalysisNodeID, removedNodeIDs.contains(currentID) {
            if let parentID, analysisNodesByID[parentID] != nil {
                currentAnalysisNodeID = parentID
            } else {
                currentAnalysisNodeID = analysisRootNodeID
            }
        }

        analysisError = nil
        clearEngineOutput()
    }

    func legalMoves(fen: String) async throws -> [String] {
        try await analysisRepository.legalMoves(fen: fen)
    }

    func updateCurrentAnalysisComment(_ comment: String) {
        guard let currentID = currentAnalysisNodeID else { return }
        updateAnalysisComment(id: currentID, comment: comment)
    }

    func updateAnalysisComment(id: UUID, comment: String) {
        guard var node = analysisNodesByID[id] else { return }
        node.comment = comment
        analysisNodesByID[id] = node
    }

    func toggleCurrentAnalysisNag(_ nag: String) {
        guard let currentID = currentAnalysisNodeID else { return }
        toggleAnalysisNag(id: currentID, nag: nag)
    }

    func toggleAnalysisNag(id: UUID, nag: String) {
        guard var node = analysisNodesByID[id] else { return }
        if let index = node.nags.firstIndex(of: nag) {
            node.nags.remove(at: index)
        } else {
            node.nags.append(nag)
        }
        analysisNodesByID[id] = node
    }

    func applyAnalysisAnnotationSymbol(id: UUID, symbol: String) {
        let principalSymbols: Set<String> = ["!!", "!", "!?", "?!", "?", "??"]
        guard var node = analysisNodesByID[id] else { return }

        if principalSymbols.contains(symbol) {
            if node.nags.contains(symbol) {
                node.nags.removeAll { $0 == symbol }
            } else {
                node.nags.removeAll { principalSymbols.contains($0) }
                node.nags.append(symbol)
            }
        } else if let index = node.nags.firstIndex(of: symbol) {
            node.nags.remove(at: index)
        } else {
            node.nags.append(symbol)
        }

        analysisNodesByID[id] = node
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
        clearAnalysisState()
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
            rebuildAnalysisTreeFromReplay()
            clearEngineOutput()
        } catch {
            stopReplayAutoPlay()
            replayFens = []
            replaySans = []
            replayUcis = []
            currentPly = 0
            clearAnalysisState()
            let message = error.localizedDescription
            if message.contains("MissingMovetext") || message.contains("GameNotFound") {
                replayError = nil
            } else {
                replayError = message
            }
            clearEngineOutput()
        }
    }

    private func appendAnalysisChild(parentID: UUID, childID: UUID) {
        guard var parent = analysisNodesByID[parentID] else { return }
        parent.children.append(childID)
        analysisNodesByID[parentID] = parent
    }

    private func collectAnalysisSubtreeIDs(startingAt rootID: UUID) -> Set<UUID> {
        var visited = Set<UUID>()
        var stack: [UUID] = [rootID]

        while let nodeID = stack.popLast() {
            guard !visited.contains(nodeID) else { continue }
            visited.insert(nodeID)

            guard let node = analysisNodesByID[nodeID] else { continue }
            stack.append(contentsOf: node.children)
        }

        return visited
    }

    private func selectAnalysisStepNode(_ nodeID: UUID) {
        if let mainlinePly = analysisNodeIDByPly.firstIndex(of: nodeID) {
            setReplayPly(mainlinePly)
            return
        }

        guard analysisNodesByID[nodeID] != nil else { return }
        currentAnalysisNodeID = nodeID
        analysisError = nil
        clearEngineOutput()
    }

    private func clearAnalysisState() {
        analysisNodesByID = [:]
        analysisNodeIDByPly = []
        analysisRootNodeID = nil
        currentAnalysisNodeID = nil
        analysisMoveInput = ""
        analysisError = nil
    }

    private func syncAnalysisSelectionToCurrentPly(clearError: Bool = false) {
        guard !analysisNodeIDByPly.isEmpty else {
            currentAnalysisNodeID = analysisRootNodeID
            if clearError {
                analysisError = nil
            }
            return
        }

        if analysisNodeIDByPly.indices.contains(currentPly) {
            currentAnalysisNodeID = analysisNodeIDByPly[currentPly]
        } else {
            currentAnalysisNodeID = analysisRootNodeID
        }

        if clearError {
            analysisError = nil
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
                    self.syncAnalysisSelectionToCurrentPly(clearError: true)
                    self.clearEngineOutput()
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
