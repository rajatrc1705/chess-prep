import Foundation

struct RustImportRepository: ImportRepository {
    func importPgn(
        dbPath: String,
        pgnPath: String,
        progress: @escaping @Sendable (ImportProgress) -> Void
    ) async throws -> ImportSummary {
        let normalizedDbPath = RustBridge.expandTilde(dbPath).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPgnPath = RustBridge.expandTilde(pgnPath).trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedDbPath.isEmpty else {
            throw RepositoryError.invalidInput("Database path is required.")
        }

        guard !normalizedPgnPath.isEmpty else {
            throw RepositoryError.invalidInput("PGN file path is required.")
        }

        guard FileManager.default.fileExists(atPath: normalizedPgnPath) else {
            throw RepositoryError.invalidInput("PGN file does not exist at '\(normalizedPgnPath)'.")
        }

        return try await Task.detached(priority: .userInitiated) {
            try importSync(dbPath: normalizedDbPath, pgnPath: normalizedPgnPath, progress: progress)
        }
        .value
    }

    private func importSync(
        dbPath: String,
        pgnPath: String,
        progress: @escaping @Sendable (ImportProgress) -> Void
    ) throws -> ImportSummary {
        let repoRoot = try RustBridge.repoRootURL()
        let binaryURL = try RustBridge.ensureBinary(repoRoot: repoRoot)
        try RustBridge.ensureDbExists(binaryURL: binaryURL, dbPath: dbPath, repoRoot: repoRoot)

        progress(ImportProgress(total: 0, inserted: 0, skipped: 0))

        let start = Date()
        let output: String

        do {
            output = try RustBridge.runProcess(
                executableURL: binaryURL,
                arguments: ["import", dbPath, pgnPath, "--tsv"],
                workingDirectory: repoRoot
            )
        } catch {
            // If binary is stale, rebuild and retry once.
            try RustBridge.buildBinary(repoRoot: repoRoot)
            output = try RustBridge.runProcess(
                executableURL: binaryURL,
                arguments: ["import", dbPath, pgnPath, "--tsv"],
                workingDirectory: repoRoot
            )
        }

        let summary = try parseImportSummary(output: output, startedAt: start)
        progress(ImportProgress(total: summary.total, inserted: summary.inserted, skipped: summary.skipped))
        return summary
    }

    private func parseImportSummary(output: String, startedAt start: Date) throws -> ImportSummary {
        let line = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

        guard let line else {
            throw RepositoryError.failure("Import did not produce a summary line.")
        }

        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let total = Int(parts[0]),
              let inserted = Int(parts[1]),
              let skipped = Int(parts[2])
        else {
            throw RepositoryError.failure("Unexpected import summary format: \(line)")
        }

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        return ImportSummary(total: total, inserted: inserted, skipped: skipped, durationMs: durationMs)
    }
}
