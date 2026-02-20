import Foundation

struct MockImportRepository: ImportRepository {
    let simulatedDelayNanoseconds: UInt64
    let finalSummary: ImportSummary

    init(
        simulatedDelayNanoseconds: UInt64 = 160_000_000,
        finalSummary: ImportSummary = ImportSummary(total: 1250, inserted: 1236, skipped: 14, errors: 0, durationMs: 1920)
    ) {
        self.simulatedDelayNanoseconds = simulatedDelayNanoseconds
        self.finalSummary = finalSummary
    }

    func importPgn(
        dbPath: String,
        pgnPath: String,
        progress: @escaping @Sendable (ImportProgress) -> Void
    ) async throws -> ImportSummary {
        let cleanDbPath = dbPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPgnPath = pgnPath.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanDbPath.isEmpty else {
            throw RepositoryError.invalidInput("Database path is required.")
        }

        guard !cleanPgnPath.isEmpty else {
            throw RepositoryError.invalidInput("PGN file path is required.")
        }

        let checkpoints = [0.10, 0.32, 0.56, 0.81, 1.0]

        for fraction in checkpoints {
            try await Task.sleep(nanoseconds: simulatedDelayNanoseconds)
            let inserted = Int(Double(finalSummary.inserted) * fraction)
            let skipped = Int(Double(finalSummary.skipped) * fraction)
            let errors = Int(Double(finalSummary.errors) * fraction)
            progress(
                ImportProgress(
                    total: finalSummary.total,
                    inserted: inserted,
                    skipped: skipped,
                    errors: errors
                )
            )
        }

        return finalSummary
    }
}
