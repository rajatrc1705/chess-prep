import Foundation

enum RepositoryError: Error, LocalizedError, Equatable, Sendable {
    case invalidInput(String)
    case failure(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return message
        case .failure(let message):
            return message
        }
    }
}

protocol GameRepository: Sendable {
    func fetchGames(databases: [WorkspaceDatabase], filter: GameFilter) async throws -> [GameSummary]
}

protocol ImportRepository: Sendable {
    func importPgn(
        dbPath: String,
        pgnPath: String,
        progress: @escaping @Sendable (ImportProgress) -> Void
    ) async throws -> ImportSummary
}

protocol ReplayRepository: Sendable {
    func fetchReplay(dbPath: String, gameID: Int64) async throws -> ReplayData
}

protocol EngineRepository: Sendable {
    func analyzePosition(
        enginePath: String,
        fen: String,
        depth: Int,
        multipv: Int
    ) async throws -> EngineAnalysis
}

protocol AnalysisRepository: Sendable {
    func applyMove(fen: String, uci: String) async throws -> AnalysisAppliedMove
    func legalMoves(fen: String) async throws -> [String]
    func saveWorkspace(
        sourceDatabasePath: String,
        gameID: Int64,
        name: String,
        rootNodeID: UUID,
        currentNodeID: UUID?,
        nodes: [AnalysisWorkspaceNodeRecord]
    ) async throws -> Int64
    func renameWorkspace(workspaceID: Int64, name: String) async throws
    func deleteWorkspace(workspaceID: Int64) async throws
    func listWorkspaces(sourceDatabasePath: String, gameID: Int64) async throws -> [AnalysisWorkspaceSummary]
    func loadWorkspace(workspaceID: Int64) async throws -> LoadedAnalysisWorkspace
}
