import Foundation

struct RustGameRepository: GameRepository {
    func fetchGames(databases: [WorkspaceDatabase], filter: GameFilter) async throws -> [GameSummary] {
        let selectedDatabases = databases.filter { $0.isActive && $0.isAvailable }
        guard !selectedDatabases.isEmpty else {
            return []
        }

        return try await Task.detached(priority: .userInitiated) {
            try fetchGamesSync(databases: selectedDatabases, filter: filter)
        }
        .value
    }

    private func fetchGamesSync(databases: [WorkspaceDatabase], filter: GameFilter) throws -> [GameSummary] {
        let repoRoot = try RustBridge.repoRootURL()
        let binaryURL = try RustBridge.ensureBinary(repoRoot: repoRoot)

        var allRows: [GameSummary] = []
        for database in databases {
            let normalizedPath = RustBridge.expandTilde(database.path).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedPath.isEmpty else { continue }
            guard FileManager.default.fileExists(atPath: normalizedPath) else { continue }

            var args = ["search", normalizedPath]

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

            let output: String
            do {
                output = try RustBridge.runProcess(executableURL: binaryURL, arguments: args, workingDirectory: repoRoot)
            } catch {
                guard RustBridge.canBuildBinary(repoRoot: repoRoot) else {
                    throw error
                }
                // If binary is stale, rebuild and retry once.
                try RustBridge.buildBinary(repoRoot: repoRoot)
                output = try RustBridge.runProcess(executableURL: binaryURL, arguments: args, workingDirectory: repoRoot)
            }

            allRows += parseRows(output, database: database, normalizedPath: normalizedPath)
        }

        allRows.sort {
            if $0.date != $1.date {
                return $0.date > $1.date
            }
            if $0.sourceDatabasePath != $1.sourceDatabasePath {
                return $0.sourceDatabasePath < $1.sourceDatabasePath
            }
            return $0.databaseID > $1.databaseID
        }

        return Array(allRows.prefix(500))
    }

    private func parseRows(_ output: String, database: WorkspaceDatabase, normalizedPath: String) -> [GameSummary] {
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
                    id: RustBridge.stableUUID(for: "\(database.id.uuidString)|\(id)"),
                    sourceDatabaseID: database.id,
                    sourceDatabaseLabel: database.label,
                    sourceDatabasePath: normalizedPath,
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
