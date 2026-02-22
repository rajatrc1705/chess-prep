import Foundation

struct RustReplayRepository: ReplayRepository {
    func fetchReplay(dbPath: String, gameID: Int64) async throws -> ReplayData {
        let normalizedPath = RustBridge.expandTilde(dbPath).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            throw RepositoryError.invalidInput("Database path is required.")
        }

        return try await Task.detached(priority: .userInitiated) {
            try fetchReplaySync(dbPath: normalizedPath, gameID: gameID)
        }
        .value
    }

    private func fetchReplaySync(dbPath: String, gameID: Int64) throws -> ReplayData {
        let repoRoot = try RustBridge.repoRootURL()
        let binaryURL = try RustBridge.ensureBinary(repoRoot: repoRoot)
        try RustBridge.ensureDbExists(binaryURL: binaryURL, dbPath: dbPath, repoRoot: repoRoot)

        let args = ["replay-meta", dbPath, String(gameID)]
        let output: String

        do {
            output = try RustBridge.runProcess(
                executableURL: binaryURL,
                arguments: args,
                workingDirectory: repoRoot
            )
        } catch {
            guard RustBridge.canBuildBinary(repoRoot: repoRoot) else {
                throw error
            }
            // If binary is stale, rebuild and retry once.
            try RustBridge.buildBinary(repoRoot: repoRoot)
            output = try RustBridge.runProcess(
                executableURL: binaryURL,
                arguments: args,
                workingDirectory: repoRoot
            )
        }

        return try parseReplay(output)
    }

    private func parseReplay(_ output: String) throws -> ReplayData {
        var fens: [String] = []
        var sans: [String] = []
        var ucis: [String] = []

        let lines = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        for line in lines {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 4 else {
                throw RepositoryError.failure("Unexpected replay format: \(line)")
            }

            guard let ply = Int(columns[0]) else {
                throw RepositoryError.failure("Unexpected replay ply value: \(line)")
            }

            let fen = String(columns[1])
            let uci = String(columns[2])
            let san = String(columns[3])

            if ply != fens.count {
                throw RepositoryError.failure("Replay payload has non-sequential plies.")
            }
            fens.append(fen)

            if ply > 0 {
                sans.append(san)
                ucis.append(uci)
            }
        }

        if fens.isEmpty {
            throw RepositoryError.failure("Replay returned no positions.")
        }

        if sans.count + 1 != fens.count || ucis.count + 1 != fens.count {
            throw RepositoryError.failure("Replay payload lengths are inconsistent.")
        }

        return ReplayData(fens: fens, sans: sans, ucis: ucis)
    }
}
