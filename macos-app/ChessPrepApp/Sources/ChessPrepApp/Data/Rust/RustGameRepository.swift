import Foundation

struct RustGameRepository: GameRepository {
    func fetchGames(dbPath: String, filter: GameFilter) async throws -> [GameSummary] {
        let normalizedPath = RustBridge.expandTilde(dbPath).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            throw RepositoryError.invalidInput("Database path is required.")
        }

        return try await Task.detached(priority: .userInitiated) {
            try fetchGamesSync(dbPath: normalizedPath, filter: filter)
        }
        .value
    }

    private func fetchGamesSync(dbPath: String, filter: GameFilter) throws -> [GameSummary] {
        let repoRoot = try RustBridge.repoRootURL()
        let binaryURL = try RustBridge.ensureBinary(repoRoot: repoRoot)
        try RustBridge.ensureDbExists(binaryURL: binaryURL, dbPath: dbPath, repoRoot: repoRoot)

        var args = ["search", dbPath]

        if let searchText = RustBridge.normalized(filter.searchText) {
            args += ["--search-text", searchText]
        }

        switch filter.result {
        case .any:
            break
        case .whiteWin:
            args += ["--result", "1-0"]
        case .blackWin:
            args += ["--result", "0-1"]
        case .draw:
            args += ["--result", "1/2-1/2"]
        }

        if let eco = RustBridge.normalized(filter.eco) {
            args += ["--eco", eco]
        }

        if let eventOrSite = RustBridge.normalized(filter.eventOrSite) {
            args += ["--event-or-site", eventOrSite]
        }

        if let dateFrom = RustBridge.normalized(filter.dateFrom) {
            args += ["--date-from", dateFrom]
        }

        if let dateTo = RustBridge.normalized(filter.dateTo) {
            args += ["--date-to", dateTo]
        }

        args += ["--limit", "500", "--offset", "0"]

        do {
            let output = try RustBridge.runProcess(executableURL: binaryURL, arguments: args, workingDirectory: repoRoot)
            return parseRows(output)
        } catch {
            // If binary is stale, rebuild and retry once.
            try RustBridge.buildBinary(repoRoot: repoRoot)
            let output = try RustBridge.runProcess(executableURL: binaryURL, arguments: args, workingDirectory: repoRoot)
            return parseRows(output)
        }
    }

    private func parseRows(_ output: String) -> [GameSummary] {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard columns.count == 8 else {
                    return nil
                }

                guard let id = Int64(columns[0]) else {
                    return nil
                }

                return GameSummary(
                    id: RustBridge.stableUUID(for: id),
                    databaseID: id,
                    white: String(columns[1]),
                    black: String(columns[2]),
                    result: String(columns[3]),
                    date: String(columns[4]),
                    eco: String(columns[5]),
                    event: String(columns[6]),
                    site: String(columns[7])
                )
            }
    }
}
