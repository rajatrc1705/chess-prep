import Foundation

struct RustEngineRepository: EngineRepository {
    func analyzePosition(enginePath: String, fen: String, depth: Int) async throws -> EngineAnalysis {
        let normalizedEnginePath = RustBridge.expandTilde(enginePath).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFen = fen.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedEnginePath.isEmpty else {
            throw RepositoryError.invalidInput("Engine path is required.")
        }
        guard !normalizedFen.isEmpty else {
            throw RepositoryError.invalidInput("FEN is required.")
        }
        guard FileManager.default.fileExists(atPath: normalizedEnginePath) else {
            throw RepositoryError.invalidInput("Engine binary does not exist at '\(normalizedEnginePath)'.")
        }

        let safeDepth = max(depth, 1)

        return try await Task.detached(priority: .userInitiated) {
            try analyzeSync(enginePath: normalizedEnginePath, fen: normalizedFen, depth: safeDepth)
        }
        .value
    }

    private func analyzeSync(enginePath: String, fen: String, depth: Int) throws -> EngineAnalysis {
        let repoRoot = try RustBridge.repoRootURL()
        let binaryURL = try RustBridge.ensureBinary(repoRoot: repoRoot)

        let args = ["analyze", enginePath, fen, "--depth", String(depth)]
        let output: String

        do {
            output = try RustBridge.runProcess(
                executableURL: binaryURL,
                arguments: args,
                workingDirectory: repoRoot
            )
        } catch {
            // If binary is stale, rebuild and retry once.
            try RustBridge.buildBinary(repoRoot: repoRoot)
            output = try RustBridge.runProcess(
                executableURL: binaryURL,
                arguments: args,
                workingDirectory: repoRoot
            )
        }

        return try parseAnalysis(output)
    }

    private func parseAnalysis(_ output: String) throws -> EngineAnalysis {
        let line = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

        guard let line else {
            throw RepositoryError.failure("Engine did not return analysis output.")
        }

        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count == 5, let depth = Int(columns[0]) else {
            throw RepositoryError.failure("Unexpected engine output format: \(line)")
        }

        let cp = Int(columns[1])
        let mate = Int(columns[2])
        let bestMove = String(columns[3]).trimmingCharacters(in: .whitespacesAndNewlines)
        let pvText = String(columns[4]).trimmingCharacters(in: .whitespacesAndNewlines)

        return EngineAnalysis(
            depth: depth,
            scoreCp: cp,
            scoreMate: mate,
            bestMove: bestMove.isEmpty ? nil : bestMove,
            pv: pvText.isEmpty ? [] : pvText.split(separator: " ").map(String.init)
        )
    }
}
