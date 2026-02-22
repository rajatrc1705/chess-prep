import Foundation

struct RustAnalysisRepository: AnalysisRepository {
    func applyMove(fen: String, uci: String) async throws -> AnalysisAppliedMove {
        let normalizedFen = fen.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUci = uci.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedFen.isEmpty else {
            throw RepositoryError.invalidInput("FEN is required.")
        }
        guard !normalizedUci.isEmpty else {
            throw RepositoryError.invalidInput("UCI move is required.")
        }

        return try await Task.detached(priority: .userInitiated) {
            try applyMoveSync(fen: normalizedFen, uci: normalizedUci)
        }
        .value
    }

    func legalMoves(fen: String) async throws -> [String] {
        let normalizedFen = fen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFen.isEmpty else {
            throw RepositoryError.invalidInput("FEN is required.")
        }

        return try await Task.detached(priority: .userInitiated) {
            try legalMovesSync(fen: normalizedFen)
        }
        .value
    }

    private func applyMoveSync(fen: String, uci: String) throws -> AnalysisAppliedMove {
        let repoRoot = try RustBridge.repoRootURL()
        let binaryURL = try RustBridge.ensureBinary(repoRoot: repoRoot)
        let args = ["apply-uci", fen, uci]
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

        return try parseAppliedMove(output)
    }

    private func legalMovesSync(fen: String) throws -> [String] {
        let repoRoot = try RustBridge.repoRootURL()
        let binaryURL = try RustBridge.ensureBinary(repoRoot: repoRoot)
        let args = ["legal-uci", fen]
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

        return parseLegalMoves(output)
    }

    private func parseAppliedMove(_ output: String) throws -> AnalysisAppliedMove {
        let line = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

        guard let line else {
            throw RepositoryError.failure("Analysis move command returned no output.")
        }

        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count == 3 else {
            throw RepositoryError.failure("Unexpected analysis move output format: \(line)")
        }

        return AnalysisAppliedMove(
            san: String(columns[0]),
            uci: String(columns[1]),
            fen: String(columns[2])
        )
    }

    private func parseLegalMoves(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
