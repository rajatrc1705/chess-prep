import Foundation

struct MockAnalysisRepository: AnalysisRepository {
    var simulatedDelayNanoseconds: UInt64 = 30_000_000
    var rejectedUcis: Set<String> = []

    func applyMove(fen: String, uci: String) async throws -> AnalysisAppliedMove {
        let cleanFen = fen.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanUci = uci.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanFen.isEmpty else {
            throw RepositoryError.invalidInput("FEN is required.")
        }
        guard !cleanUci.isEmpty else {
            throw RepositoryError.invalidInput("UCI move is required.")
        }
        if rejectedUcis.contains(cleanUci) {
            throw RepositoryError.failure("Illegal move: \(cleanUci)")
        }

        try await Task.sleep(nanoseconds: simulatedDelayNanoseconds)

        let san: String
        if cleanUci.count >= 4 {
            let start = cleanUci.index(cleanUci.startIndex, offsetBy: 2)
            let end = cleanUci.index(cleanUci.startIndex, offsetBy: 4)
            san = String(cleanUci[start..<end])
        } else {
            san = cleanUci
        }

        return AnalysisAppliedMove(
            san: san,
            uci: cleanUci,
            fen: "\(cleanFen) | \(cleanUci)"
        )
    }

    func legalMoves(fen: String) async throws -> [String] {
        let cleanFen = fen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanFen.isEmpty else {
            throw RepositoryError.invalidInput("FEN is required.")
        }

        try await Task.sleep(nanoseconds: simulatedDelayNanoseconds)

        // Minimal deterministic set for tests/previews.
        return ["e2e4", "d2d4", "g1f3", "b1c3"]
    }

    func saveWorkspace(
        sourceDatabasePath: String,
        gameID: Int64,
        name: String,
        rootNodeID: UUID,
        currentNodeID: UUID?,
        nodes: [AnalysisWorkspaceNodeRecord]
    ) async throws -> Int64 {
        let cleanSourcePath = sourceDatabasePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSourcePath.isEmpty else {
            throw RepositoryError.invalidInput("Source database path is required.")
        }
        guard !cleanName.isEmpty else {
            throw RepositoryError.invalidInput("Workspace name is required.")
        }
        guard !nodes.isEmpty else {
            throw RepositoryError.invalidInput("At least one analysis node is required.")
        }
        _ = gameID
        _ = rootNodeID
        _ = currentNodeID
        return Int64(Date().timeIntervalSince1970)
    }

    func renameWorkspace(workspaceID: Int64, name: String) async throws {
        _ = workspaceID
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw RepositoryError.invalidInput("Workspace name is required.")
        }
    }

    func deleteWorkspace(workspaceID: Int64) async throws {
        _ = workspaceID
    }

    func listWorkspaces(sourceDatabasePath: String, gameID: Int64) async throws -> [AnalysisWorkspaceSummary] {
        let cleanSourcePath = sourceDatabasePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanSourcePath.isEmpty else {
            throw RepositoryError.invalidInput("Source database path is required.")
        }
        _ = gameID
        return []
    }

    func loadWorkspace(workspaceID: Int64) async throws -> LoadedAnalysisWorkspace {
        _ = workspaceID
        throw RepositoryError.failure("No saved analysis workspace available in mock repository.")
    }
}
