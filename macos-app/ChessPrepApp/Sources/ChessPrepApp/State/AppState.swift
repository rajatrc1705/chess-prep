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
    @Published var analysisWorkspaceName = ""
    @Published var analysisWorkspaceSummaries: [AnalysisWorkspaceSummary] = []
    @Published var selectedAnalysisWorkspaceID: Int64?
    @Published var isSavingAnalysisWorkspace = false
    @Published var isRenamingAnalysisWorkspace = false
    @Published var isDeletingAnalysisWorkspace = false
    @Published var isLoadingAnalysisWorkspaceList = false
    @Published var isLoadingAnalysisWorkspace = false
    @Published var analysisWorkspaceError: String?
    @Published var analysisWorkspaceStatus: String?
    @Published var loadedAnalysisWorkspaceID: Int64?
    @Published var loadedAnalysisWorkspaceName: String?
    @Published var lastSavedAnalysisWorkspaceID: Int64?
    @Published var lastSavedAnalysisWorkspaceName: String?
    @Published var analysisWorkspaceIsDirty = false
    @Published var analysisPathGraphPoints: [AnalysisPathGraphPoint] = []
    @Published var isLoadingAnalysisPathGraph = false
    @Published var analysisPathGraphProgressText: String?
    @Published var analysisPathGraphError: String?
    @Published var analysisPathGraphIsTruncated = false
    @Published var enginePath = ""
    @Published var engineDepth = 18
    @Published var engineTopLineCount = 1
    @Published var autoAnalyzeEngine = true
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
    private var autoAnalyzeTask: Task<Void, Never>?
    private var analysisPathGraphTask: Task<Void, Never>?
    private var pendingAutoAnalyzeRequest: EngineRequestSignature?
    private var lastEngineRequest: EngineRequestSignature?
    private var analysisPathGraphCache: [PathGraphCacheKey: PathGraphCachedScore] = [:]
    private var lastAnalysisPathGraphSignature: PathGraphRequestSignature?
    private let analysisPathGraphMaxPlies = 120

    private struct EngineRequestSignature: Equatable {
        let fen: String
        let enginePath: String
        let depth: Int
        let multipv: Int
    }

    private struct PathGraphCachedScore: Equatable {
        let scoreCp: Int?
        let scoreMate: Int?
    }

    private struct PathGraphCacheKey: Hashable {
        let enginePath: String
        let depth: Int
        let fen: String
    }

    private struct PathGraphRequestSignature: Equatable {
        let nodeIDs: [UUID]
        let enginePath: String
        let depth: Int
    }

    private struct PathGraphNodeInput {
        let nodeID: UUID
        let ply: Int
        let fen: String
    }

    private struct PathGraphRequest {
        let signature: PathGraphRequestSignature
        let nodeInputs: [PathGraphNodeInput]
        let enginePath: String
        let depth: Int
        let isTruncated: Bool
    }

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
        guard let fenToAnalyze = currentAnalysisFen ?? currentFen else {
            engineError = "No position selected."
            engineAnalysis = nil
            return
        }
        let normalizedEnginePath = enginePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEnginePath.isEmpty else {
            engineError = "Select an engine first."
            engineAnalysis = nil
            return
        }

        guard let request = engineRequestSignature(for: fenToAnalyze) else {
            engineError = "No position selected."
            engineAnalysis = nil
            return
        }

        await analyzeEngine(request: request, force: true)
    }

    func scheduleAutoAnalyze(for fen: String?) {
        autoAnalyzeTask?.cancel()
        autoAnalyzeTask = nil

        guard autoAnalyzeEngine else { return }
        guard let request = engineRequestSignature(for: fen) else { return }

        autoAnalyzeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.analyzeEngine(request: request, force: false)
        }
    }

    private func engineRequestSignature(for fen: String?) -> EngineRequestSignature? {
        guard let fen else { return nil }
        let normalizedFen = fen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFen.isEmpty else { return nil }

        let normalizedEnginePath = enginePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEnginePath.isEmpty else { return nil }

        return EngineRequestSignature(
            fen: normalizedFen,
            enginePath: normalizedEnginePath,
            depth: max(engineDepth, 1),
            multipv: max(1, min(engineTopLineCount, 3))
        )
    }

    private func analyzeEngine(request: EngineRequestSignature, force: Bool) async {
        if !force,
           request == lastEngineRequest,
           engineAnalysis != nil {
            return
        }

        if isAnalyzingEngine {
            if !force {
                pendingAutoAnalyzeRequest = request
            }
            return
        }

        isAnalyzingEngine = true
        engineError = nil
        defer {
            isAnalyzingEngine = false

            if let pending = pendingAutoAnalyzeRequest {
                pendingAutoAnalyzeRequest = nil
                if pending != lastEngineRequest {
                    Task { [weak self] in
                        await self?.analyzeEngine(request: pending, force: false)
                    }
                }
            }
        }

        do {
            let analysis = try await engineRepository.analyzePosition(
                enginePath: request.enginePath,
                fen: request.fen,
                depth: request.depth,
                multipv: request.multipv
            )
            engineAnalysis = analysis
            lastEngineRequest = request
        } catch {
            engineAnalysis = nil
            engineError = error.localizedDescription
        }
    }

    func scheduleAnalysisPathGraphEvaluation() {
        analysisPathGraphTask?.cancel()
        analysisPathGraphTask = nil

        guard let request = makeAnalysisPathGraphRequest() else {
            clearAnalysisPathGraphState(clearCache: false)
            return
        }

        let alreadyResolved = request.signature == lastAnalysisPathGraphSignature
            && analysisPathGraphError == nil
            && analysisPathGraphPoints.count == request.nodeInputs.count
            && analysisPathGraphPoints.allSatisfy(\.isEvaluated)

        if alreadyResolved {
            analysisPathGraphIsTruncated = request.isTruncated
            return
        }

        analysisPathGraphPoints = request.nodeInputs.map { input in
            AnalysisPathGraphPoint(
                nodeID: input.nodeID,
                ply: input.ply,
                scoreCp: nil,
                scoreMate: nil,
                isEvaluated: false
            )
        }
        analysisPathGraphError = nil
        analysisPathGraphProgressText = "Evaluating 0/\(request.nodeInputs.count)"
        analysisPathGraphIsTruncated = request.isTruncated
        isLoadingAnalysisPathGraph = true
        lastAnalysisPathGraphSignature = request.signature

        analysisPathGraphTask = Task { [weak self] in
            await self?.runAnalysisPathGraphEvaluation(request)
        }
    }

    private func runAnalysisPathGraphEvaluation(_ request: PathGraphRequest) async {
        let total = request.nodeInputs.count
        var completed = 0

        for input in request.nodeInputs {
            guard !Task.isCancelled else { return }

            let cacheKey = PathGraphCacheKey(
                enginePath: request.enginePath,
                depth: request.depth,
                fen: input.fen
            )

            let score: PathGraphCachedScore
            if let cached = analysisPathGraphCache[cacheKey] {
                score = cached
            } else {
                do {
                    let analysis = try await engineRepository.analyzePosition(
                        enginePath: request.enginePath,
                        fen: input.fen,
                        depth: request.depth,
                        multipv: 1
                    )
                    score = PathGraphCachedScore(
                        scoreCp: analysis.scoreCp,
                        scoreMate: analysis.scoreMate
                    )
                    analysisPathGraphCache[cacheKey] = score
                } catch {
                    guard !Task.isCancelled else { return }
                    analysisPathGraphError = error.localizedDescription
                    analysisPathGraphProgressText = nil
                    isLoadingAnalysisPathGraph = false
                    return
                }
            }

            if let index = analysisPathGraphPoints.firstIndex(where: { $0.nodeID == input.nodeID }) {
                analysisPathGraphPoints[index].scoreCp = score.scoreCp
                analysisPathGraphPoints[index].scoreMate = score.scoreMate
                analysisPathGraphPoints[index].isEvaluated = true
            }

            completed += 1
            if completed < total {
                analysisPathGraphProgressText = "Evaluating \(completed)/\(total)"
            } else {
                analysisPathGraphProgressText = nil
            }
        }

        isLoadingAnalysisPathGraph = false
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
            markAnalysisWorkspaceDirty()
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
        markAnalysisWorkspaceDirty()
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
        if node.comment == comment {
            return
        }
        node.comment = comment
        analysisNodesByID[id] = node
        markAnalysisWorkspaceDirty()
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
        markAnalysisWorkspaceDirty()
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
        markAnalysisWorkspaceDirty()
    }

    func refreshAnalysisWorkspaces() async {
        guard let game = selectedGame else {
            clearAnalysisWorkspaceState()
            return
        }

        isLoadingAnalysisWorkspaceList = true
        analysisWorkspaceError = nil
        defer { isLoadingAnalysisWorkspaceList = false }

        do {
            let summaries = try await analysisRepository.listWorkspaces(
                sourceDatabasePath: game.sourceDatabasePath,
                gameID: game.databaseID
            )
            analysisWorkspaceSummaries = summaries

            if let selected = selectedAnalysisWorkspaceID,
               summaries.contains(where: { $0.id == selected }) {
                // Keep current selection.
            } else {
                selectedAnalysisWorkspaceID = summaries.first?.id
            }

            if let loadedID = loadedAnalysisWorkspaceID,
               let loadedSummary = summaries.first(where: { $0.id == loadedID }) {
                loadedAnalysisWorkspaceName = loadedSummary.name
            } else if loadedAnalysisWorkspaceID != nil {
                loadedAnalysisWorkspaceID = nil
                loadedAnalysisWorkspaceName = nil
                analysisWorkspaceIsDirty = false
            }

            if let lastSavedID = lastSavedAnalysisWorkspaceID,
               let savedSummary = summaries.first(where: { $0.id == lastSavedID }) {
                lastSavedAnalysisWorkspaceName = savedSummary.name
            } else if lastSavedAnalysisWorkspaceID != nil {
                lastSavedAnalysisWorkspaceID = nil
                lastSavedAnalysisWorkspaceName = nil
            }
        } catch {
            analysisWorkspaceSummaries = []
            selectedAnalysisWorkspaceID = nil
            analysisWorkspaceError = error.localizedDescription
        }
    }

    func saveCurrentAnalysisWorkspace() async {
        guard let game = selectedGame else {
            analysisWorkspaceError = "Select a game first."
            return
        }
        guard let rootNodeID = analysisRootNodeID else {
            analysisWorkspaceError = "No analysis tree to save."
            return
        }

        let nodes = buildAnalysisWorkspaceNodeRecords(rootNodeID: rootNodeID)
        guard !nodes.isEmpty else {
            analysisWorkspaceError = "No analysis nodes available to save."
            return
        }

        let trimmedName = analysisWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspaceName = trimmedName.isEmpty ? defaultAnalysisWorkspaceName() : trimmedName

        isSavingAnalysisWorkspace = true
        analysisWorkspaceError = nil
        analysisWorkspaceStatus = nil
        defer { isSavingAnalysisWorkspace = false }

        do {
            let savedWorkspaceID = try await analysisRepository.saveWorkspace(
                sourceDatabasePath: game.sourceDatabasePath,
                gameID: game.databaseID,
                name: workspaceName,
                rootNodeID: rootNodeID,
                currentNodeID: currentAnalysisNodeID,
                nodes: nodes
            )
            analysisWorkspaceName = workspaceName
            await refreshAnalysisWorkspaces()
            selectedAnalysisWorkspaceID = savedWorkspaceID
            loadedAnalysisWorkspaceID = savedWorkspaceID
            loadedAnalysisWorkspaceName = workspaceName
            lastSavedAnalysisWorkspaceID = savedWorkspaceID
            lastSavedAnalysisWorkspaceName = workspaceName
            analysisWorkspaceIsDirty = false
            analysisWorkspaceStatus = "Saved \"\(workspaceName)\"."
        } catch {
            analysisWorkspaceError = error.localizedDescription
        }
    }

    func loadSelectedAnalysisWorkspace() async {
        guard let selectedWorkspaceID = selectedAnalysisWorkspaceID else {
            analysisWorkspaceError = "Select a saved analysis first."
            return
        }
        guard let game = selectedGame else {
            analysisWorkspaceError = "Select a game first."
            return
        }

        isLoadingAnalysisWorkspace = true
        analysisWorkspaceError = nil
        analysisWorkspaceStatus = nil
        defer { isLoadingAnalysisWorkspace = false }

        do {
            let loaded = try await analysisRepository.loadWorkspace(workspaceID: selectedWorkspaceID)

            let normalizedLoadedPath = normalizePath(loaded.workspace.sourceDatabasePath)
            let normalizedSelectedPath = normalizePath(game.sourceDatabasePath)
            guard normalizedLoadedPath == normalizedSelectedPath,
                  loaded.workspace.gameID == game.databaseID else {
                throw RepositoryError.invalidInput("Selected workspace belongs to a different game.")
            }

            applyLoadedAnalysisWorkspace(loaded)
            analysisWorkspaceName = loaded.workspace.name
            loadedAnalysisWorkspaceID = loaded.workspace.id
            loadedAnalysisWorkspaceName = loaded.workspace.name
            analysisWorkspaceIsDirty = false
            analysisWorkspaceStatus = "Loaded \"\(loaded.workspace.name)\"."
        } catch {
            analysisWorkspaceError = error.localizedDescription
        }
    }

    func renameSelectedAnalysisWorkspace() async {
        guard let workspaceID = selectedAnalysisWorkspaceID else {
            analysisWorkspaceError = "Select a saved analysis first."
            return
        }
        let trimmedName = analysisWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            analysisWorkspaceError = "Workspace name is required."
            return
        }

        isRenamingAnalysisWorkspace = true
        analysisWorkspaceError = nil
        analysisWorkspaceStatus = nil
        defer { isRenamingAnalysisWorkspace = false }

        do {
            try await analysisRepository.renameWorkspace(workspaceID: workspaceID, name: trimmedName)
            await refreshAnalysisWorkspaces()
            selectedAnalysisWorkspaceID = workspaceID

            if loadedAnalysisWorkspaceID == workspaceID {
                loadedAnalysisWorkspaceName = trimmedName
            }
            if lastSavedAnalysisWorkspaceID == workspaceID {
                lastSavedAnalysisWorkspaceName = trimmedName
            }
            analysisWorkspaceName = trimmedName
            analysisWorkspaceStatus = "Renamed workspace to \"\(trimmedName)\"."
        } catch {
            analysisWorkspaceError = error.localizedDescription
        }
    }

    func deleteSelectedAnalysisWorkspace() async {
        guard let workspaceID = selectedAnalysisWorkspaceID else {
            analysisWorkspaceError = "Select a saved analysis first."
            return
        }

        let deletedName = analysisWorkspaceSummaries
            .first(where: { $0.id == workspaceID })?
            .name ?? "Workspace"

        isDeletingAnalysisWorkspace = true
        analysisWorkspaceError = nil
        analysisWorkspaceStatus = nil
        defer { isDeletingAnalysisWorkspace = false }

        do {
            try await analysisRepository.deleteWorkspace(workspaceID: workspaceID)
            if loadedAnalysisWorkspaceID == workspaceID {
                loadedAnalysisWorkspaceID = nil
                loadedAnalysisWorkspaceName = nil
                analysisWorkspaceIsDirty = false
            }
            if lastSavedAnalysisWorkspaceID == workspaceID {
                lastSavedAnalysisWorkspaceID = nil
                lastSavedAnalysisWorkspaceName = nil
            }

            await refreshAnalysisWorkspaces()
            analysisWorkspaceStatus = "Deleted \"\(deletedName)\"."
        } catch {
            analysisWorkspaceError = error.localizedDescription
        }
    }

    func registerDatabase(path: String, label: String? = nil) {
        workspaceError = nil
        let normalizedPath = RustBridge.expandTilde(path).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            workspaceError = "Database path is required."
            return
        }

        if let existingIndex = workspaceDatabases.firstIndex(where: { normalizePath($0.path) == normalizePath(normalizedPath) }) {
            workspaceDatabases[existingIndex].isActive = true
            workspaceDatabases[existingIndex].updatedAt = Date()
            selectedImportDatabaseID = workspaceDatabases[existingIndex].id
            saveWorkspaceDatabases()
            reloadWithCurrentFilter()
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
        reloadWithCurrentFilter()
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

    private func buildAnalysisWorkspaceNodeRecords(rootNodeID: UUID) -> [AnalysisWorkspaceNodeRecord] {
        var out: [AnalysisWorkspaceNodeRecord] = []
        var visited = Set<UUID>()

        func visit(nodeID: UUID, parentID: UUID?, sortIndex: Int) {
            guard visited.insert(nodeID).inserted else { return }
            guard let node = analysisNodesByID[nodeID] else { return }

            out.append(
                AnalysisWorkspaceNodeRecord(
                    id: node.id,
                    parentID: parentID,
                    san: node.san,
                    uci: node.uci,
                    fen: node.fen,
                    comment: node.comment,
                    nags: node.nags,
                    sortIndex: sortIndex
                )
            )

            for (index, childID) in node.children.enumerated() {
                visit(nodeID: childID, parentID: nodeID, sortIndex: index)
            }
        }

        visit(nodeID: rootNodeID, parentID: nil, sortIndex: 0)
        return out
    }

    private func applyLoadedAnalysisWorkspace(_ loaded: LoadedAnalysisWorkspace) {
        var nodesByID: [UUID: AnalysisNode] = [:]
        var childrenByParent: [UUID: [(id: UUID, sortIndex: Int)]] = [:]

        for node in loaded.nodes {
            nodesByID[node.id] = AnalysisNode(
                id: node.id,
                parentID: node.parentID,
                san: node.san,
                uci: node.uci,
                fen: node.fen,
                comment: node.comment,
                nags: node.nags,
                children: []
            )

            if let parentID = node.parentID {
                childrenByParent[parentID, default: []].append((id: node.id, sortIndex: node.sortIndex))
            }
        }

        for (parentID, children) in childrenByParent {
            guard var parent = nodesByID[parentID] else { continue }
            parent.children = children
                .sorted { lhs, rhs in
                    if lhs.sortIndex == rhs.sortIndex {
                        return lhs.id.uuidString < rhs.id.uuidString
                    }
                    return lhs.sortIndex < rhs.sortIndex
                }
                .map(\.id)
            nodesByID[parentID] = parent
        }

        guard !nodesByID.isEmpty else {
            clearAnalysisState()
            return
        }

        let rootNodeID = nodesByID[loaded.workspace.rootNodeID] != nil
            ? loaded.workspace.rootNodeID
            : loaded.nodes.first(where: { $0.parentID == nil })?.id ?? loaded.nodes.first?.id

        guard let rootNodeID else {
            clearAnalysisState()
            return
        }

        analysisNodesByID = nodesByID
        analysisRootNodeID = rootNodeID
        analysisNodeIDByPly = buildMainlineNodeIDs(rootNodeID: rootNodeID, nodesByID: nodesByID)

        let selectedNodeID: UUID = {
            if let currentID = loaded.workspace.currentNodeID, nodesByID[currentID] != nil {
                return currentID
            }
            return rootNodeID
        }()

        currentAnalysisNodeID = selectedNodeID
        currentPly = anchorPly(
            for: selectedNodeID,
            mainline: analysisNodeIDByPly,
            nodesByID: nodesByID
        )
        analysisError = nil
        clearEngineOutput()
    }

    private func buildMainlineNodeIDs(
        rootNodeID: UUID,
        nodesByID: [UUID: AnalysisNode]
    ) -> [UUID] {
        var out: [UUID] = []
        var visited = Set<UUID>()
        var cursor: UUID? = rootNodeID

        while let nodeID = cursor, visited.insert(nodeID).inserted {
            out.append(nodeID)
            cursor = nodesByID[nodeID]?.children.first
        }

        return out
    }

    private func anchorPly(
        for selectedNodeID: UUID,
        mainline: [UUID],
        nodesByID: [UUID: AnalysisNode]
    ) -> Int {
        if let direct = mainline.firstIndex(of: selectedNodeID) {
            return direct
        }

        var cursor: UUID? = selectedNodeID
        var visited = Set<UUID>()
        while let nodeID = cursor, visited.insert(nodeID).inserted {
            if let index = mainline.firstIndex(of: nodeID) {
                return index
            }
            cursor = nodesByID[nodeID]?.parentID
        }

        return 0
    }

    private func defaultAnalysisWorkspaceName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Analysis \(formatter.string(from: Date()))"
    }

    private func makeAnalysisPathGraphRequest() -> PathGraphRequest? {
        guard let rootNodeID = analysisRootNodeID else { return nil }

        let normalizedEnginePath = enginePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEnginePath.isEmpty else { return nil }

        let depth = max(engineDepth, 1)
        let selectedNodeID = {
            guard let currentAnalysisNodeID else { return rootNodeID }
            return analysisNodesByID[currentAnalysisNodeID] != nil ? currentAnalysisNodeID : rootNodeID
        }()

        let fullPathNodeIDs = currentExploredPathNodeIDs(
            rootNodeID: rootNodeID,
            selectedNodeID: selectedNodeID
        )
        guard !fullPathNodeIDs.isEmpty else { return nil }

        let isTruncated = fullPathNodeIDs.count > analysisPathGraphMaxPlies
        let limitedNodeIDs = Array(fullPathNodeIDs.prefix(analysisPathGraphMaxPlies))

        let nodeInputs: [PathGraphNodeInput] = limitedNodeIDs.enumerated().compactMap { entry in
            let (index, nodeID) = entry
            guard let fen = analysisNodesByID[nodeID]?.fen else { return nil }
            return PathGraphNodeInput(nodeID: nodeID, ply: index, fen: fen)
        }

        guard !nodeInputs.isEmpty else { return nil }

        let signature = PathGraphRequestSignature(
            nodeIDs: nodeInputs.map { $0.nodeID },
            enginePath: normalizedEnginePath,
            depth: depth
        )

        return PathGraphRequest(
            signature: signature,
            nodeInputs: nodeInputs,
            enginePath: normalizedEnginePath,
            depth: depth,
            isTruncated: isTruncated
        )
    }

    private func currentExploredPathNodeIDs(rootNodeID: UUID, selectedNodeID: UUID) -> [UUID] {
        var ancestorPath: [UUID] = []
        var visited = Set<UUID>()
        var cursor: UUID? = selectedNodeID

        while let nodeID = cursor, visited.insert(nodeID).inserted {
            ancestorPath.append(nodeID)
            if nodeID == rootNodeID {
                break
            }
            cursor = analysisNodesByID[nodeID]?.parentID
        }

        if ancestorPath.isEmpty {
            ancestorPath = [rootNodeID]
        }

        ancestorPath.reverse()
        if ancestorPath.first != rootNodeID {
            ancestorPath.insert(rootNodeID, at: 0)
        }

        var path = ancestorPath
        visited = Set(path)
        var tailCursor = ancestorPath.last ?? rootNodeID

        while let nextNodeID = analysisNodesByID[tailCursor]?.children.first,
              visited.insert(nextNodeID).inserted {
            path.append(nextNodeID)
            tailCursor = nextNodeID
        }

        return path
    }

    private func clearAnalysisPathGraphState(clearCache: Bool) {
        analysisPathGraphTask?.cancel()
        analysisPathGraphTask = nil
        analysisPathGraphPoints = []
        isLoadingAnalysisPathGraph = false
        analysisPathGraphProgressText = nil
        analysisPathGraphError = nil
        analysisPathGraphIsTruncated = false
        lastAnalysisPathGraphSignature = nil
        if clearCache {
            analysisPathGraphCache.removeAll()
        }
    }

    private func markAnalysisWorkspaceDirty() {
        guard loadedAnalysisWorkspaceID != nil else { return }
        analysisWorkspaceIsDirty = true
    }

    private func clearAnalysisWorkspaceState() {
        analysisWorkspaceName = ""
        analysisWorkspaceSummaries = []
        selectedAnalysisWorkspaceID = nil
        isSavingAnalysisWorkspace = false
        isRenamingAnalysisWorkspace = false
        isDeletingAnalysisWorkspace = false
        isLoadingAnalysisWorkspaceList = false
        isLoadingAnalysisWorkspace = false
        analysisWorkspaceError = nil
        analysisWorkspaceStatus = nil
        loadedAnalysisWorkspaceID = nil
        loadedAnalysisWorkspaceName = nil
        lastSavedAnalysisWorkspaceID = nil
        lastSavedAnalysisWorkspaceName = nil
        analysisWorkspaceIsDirty = false
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
        clearAnalysisWorkspaceState()
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
            await refreshAnalysisWorkspaces()
            clearEngineOutput()
        } catch {
            stopReplayAutoPlay()
            replayFens = []
            replaySans = []
            replayUcis = []
            currentPly = 0
            clearAnalysisState()
            clearAnalysisWorkspaceState()
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
        clearAnalysisPathGraphState(clearCache: false)
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
        autoAnalyzeTask?.cancel()
        autoAnalyzeTask = nil
        pendingAutoAnalyzeRequest = nil
        lastEngineRequest = nil
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
