import Foundation

struct RustImportRepository: ImportRepository {
    private enum ImportLine {
        case progress(total: Int, inserted: Int, skipped: Int, errors: Int)
        case summary(total: Int, inserted: Int, skipped: Int, errors: Int)
    }

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

        progress(ImportProgress(total: 0, inserted: 0, skipped: 0, errors: 0))

        let start = Date()
        let output: String
        let finalSummary: ImportSummary?

        do {
            let result = try runImportProcess(
                executableURL: binaryURL,
                dbPath: dbPath,
                pgnPath: pgnPath,
                repoRoot: repoRoot,
                startedAt: start,
                progress: progress
            )
            output = result.output
            finalSummary = result.summary
        } catch {
            // If binary is stale, rebuild and retry once.
            try RustBridge.buildBinary(repoRoot: repoRoot)
            let result = try runImportProcess(
                executableURL: binaryURL,
                dbPath: dbPath,
                pgnPath: pgnPath,
                repoRoot: repoRoot,
                startedAt: start,
                progress: progress
            )
            output = result.output
            finalSummary = result.summary
        }

        if let finalSummary {
            progress(
                ImportProgress(
                    total: finalSummary.total,
                    inserted: finalSummary.inserted,
                    skipped: finalSummary.skipped,
                    errors: finalSummary.errors
                )
            )
            return finalSummary
        }

        let summary = try parseImportSummary(output: output, startedAt: start)
        progress(
            ImportProgress(
                total: summary.total,
                inserted: summary.inserted,
                skipped: summary.skipped,
                errors: summary.errors
            )
        )
        return summary
    }

    private func runImportProcess(
        executableURL: URL,
        dbPath: String,
        pgnPath: String,
        repoRoot: URL,
        startedAt start: Date,
        progress: @escaping @Sendable (ImportProgress) -> Void
    ) throws -> (output: String, summary: ImportSummary?) {
        final class SummaryBox: @unchecked Sendable {
            private let lock = NSLock()
            private var summary: ImportSummary?

            func set(_ summary: ImportSummary) {
                lock.lock()
                self.summary = summary
                lock.unlock()
            }

            func get() -> ImportSummary? {
                lock.lock()
                let current = summary
                lock.unlock()
                return current
            }
        }

        let summaryBox = SummaryBox()
        let output = try RustBridge.runProcessStreaming(
            executableURL: executableURL,
            arguments: ["import", dbPath, pgnPath, "--tsv"],
            workingDirectory: repoRoot,
            onStdoutLine: { line in
                guard let parsed = parseImportLine(line: line) else { return }

                switch parsed {
                case .progress(let total, let inserted, let skipped, let errors):
                    progress(
                        ImportProgress(
                            total: total,
                            inserted: inserted,
                            skipped: skipped,
                            errors: errors
                        )
                    )
                case .summary(let total, let inserted, let skipped, let errors):
                    let durationMs = Int(Date().timeIntervalSince(start) * 1000)
                    summaryBox.set(
                        ImportSummary(
                            total: total,
                            inserted: inserted,
                            skipped: skipped,
                            errors: errors,
                            durationMs: durationMs
                        )
                    )
                }
            }
        )
        let summary = summaryBox.get()
        return (output, summary)
    }

    private func parseImportLine(line: String) -> ImportLine? {
        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }

        let parts = clean.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 5 else { return nil }
        guard let total = Int(parts[1]),
              let inserted = Int(parts[2]),
              let skipped = Int(parts[3]),
              let errors = Int(parts[4])
        else {
            return nil
        }

        switch parts[0] {
        case "progress":
            return .progress(total: total, inserted: inserted, skipped: skipped, errors: errors)
        case "summary":
            return .summary(total: total, inserted: inserted, skipped: skipped, errors: errors)
        default:
            return nil
        }
    }

    private func parseImportSummary(output: String, startedAt start: Date) throws -> ImportSummary {
        let line = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

        guard let line else {
            throw RepositoryError.failure("Import did not produce a summary line.")
        }

        let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = clean.split(separator: "\t", omittingEmptySubsequences: false)

        let total: Int
        let inserted: Int
        let skipped: Int
        let errors: Int

        if parts.count == 5, parts[0] == "summary",
           let parsedTotal = Int(parts[1]),
           let parsedInserted = Int(parts[2]),
           let parsedSkipped = Int(parts[3]),
           let parsedErrors = Int(parts[4]) {
            total = parsedTotal
            inserted = parsedInserted
            skipped = parsedSkipped
            errors = parsedErrors
        } else if parts.count == 3,
                  let parsedTotal = Int(parts[0]),
                  let parsedInserted = Int(parts[1]),
                  let parsedSkipped = Int(parts[2]) {
            // Backward compatibility with prior Rust output format.
            total = parsedTotal
            inserted = parsedInserted
            skipped = parsedSkipped
            errors = 0
        } else {
            throw RepositoryError.failure("Unexpected import summary format: \(line)")
        }

        let durationMs = Int(Date().timeIntervalSince(start) * 1000)
        return ImportSummary(
            total: total,
            inserted: inserted,
            skipped: skipped,
            errors: errors,
            durationMs: durationMs
        )
    }
}
