import Foundation

struct MockGameRepository: GameRepository {
    let seedGames: [GameSummary]

    init(seedGames: [GameSummary] = MockGameRepository.previewGames) {
        self.seedGames = seedGames
    }

    func fetchGames(databases: [WorkspaceDatabase], filter: GameFilter) async throws -> [GameSummary] {
        try await Task.sleep(for: .milliseconds(110))

        let activeDatabasePaths = Set(
            databases
                .filter { $0.isActive && $0.isAvailable }
                .map { normalizePath($0.path) }
        )

        guard !activeDatabasePaths.isEmpty else {
            return []
        }

        return seedGames
            .filter { activeDatabasePaths.contains(normalizePath($0.sourceDatabasePath)) }
            .filter { filter.matches($0) }
            .sorted { lhs, rhs in
                if lhs.date != rhs.date {
                    return lhs.date > rhs.date
                }
                if lhs.sourceDatabasePath != rhs.sourceDatabasePath {
                    return lhs.sourceDatabasePath < rhs.sourceDatabasePath
                }
                return lhs.databaseID > rhs.databaseID
            }
    }

    private func normalizePath(_ path: String) -> String {
        RustBridge.expandTilde(path).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let previewDatabaseA = WorkspaceDatabase(
        id: UUID(uuidString: "CE80CF80-B862-4E3A-BA0A-38A344F07F73")!,
        label: "Main DB",
        path: "/tmp/chess-prep-main.sqlite",
        isActive: true,
        isAvailable: true,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    static let previewDatabaseB = WorkspaceDatabase(
        id: UUID(uuidString: "8CF5BEF7-C74A-406E-B0B4-08DEBDA53B3E")!,
        label: "Secondary DB",
        path: "/tmp/chess-prep-secondary.sqlite",
        isActive: true,
        isAvailable: true,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    static let previewGames: [GameSummary] = [
        GameSummary(
            id: UUID(uuidString: "80CFCE80-B862-4E3A-BA0A-38A344F07F73")!,
            sourceDatabaseID: previewDatabaseA.id,
            sourceDatabaseLabel: previewDatabaseA.label,
            sourceDatabasePath: previewDatabaseA.path,
            databaseID: 1,
            white: "Carlsen, Magnus",
            black: "Nepomniachtchi, Ian",
            result: "1-0",
            date: "2024.11.22",
            eco: "C84",
            event: "World Championship",
            site: "Singapore"
        ),
        GameSummary(
            id: UUID(uuidString: "71D49E03-75A4-474E-BC30-A7D6A8A4FC30")!,
            sourceDatabaseID: previewDatabaseA.id,
            sourceDatabaseLabel: previewDatabaseA.label,
            sourceDatabasePath: previewDatabaseA.path,
            databaseID: 2,
            white: "Gukesh, D",
            black: "Caruana, Fabiano",
            result: "1/2-1/2",
            date: "2025.01.15",
            eco: "D37",
            event: "Tata Steel",
            site: "Wijk aan Zee"
        ),
        GameSummary(
            id: UUID(uuidString: "B7D2A9A5-3FE0-4135-8D72-B9E8A2D2737E")!,
            sourceDatabaseID: previewDatabaseB.id,
            sourceDatabaseLabel: previewDatabaseB.label,
            sourceDatabasePath: previewDatabaseB.path,
            databaseID: 3,
            white: "Kramnik, Vladimir",
            black: "Anand, Viswanathan",
            result: "0-1",
            date: "2008.10.20",
            eco: "E32",
            event: "World Championship",
            site: "Bonn"
        ),
        GameSummary(
            id: UUID(uuidString: "32929A2A-1904-40E9-9A6E-6206424D10CB")!,
            sourceDatabaseID: previewDatabaseB.id,
            sourceDatabaseLabel: previewDatabaseB.label,
            sourceDatabasePath: previewDatabaseB.path,
            databaseID: 4,
            white: "Alice",
            black: "Bob",
            result: "1-0",
            date: "2024.01.01",
            eco: "C20",
            event: "Training Match",
            site: "Berlin"
        ),
        GameSummary(
            id: UUID(uuidString: "8AF5BEF7-C74A-406E-B0B4-08DEBDA53B3E")!,
            sourceDatabaseID: previewDatabaseB.id,
            sourceDatabaseLabel: previewDatabaseB.label,
            sourceDatabasePath: previewDatabaseB.path,
            databaseID: 5,
            white: "Carol",
            black: "Dave",
            result: "0-1",
            date: "2024.01.02",
            eco: "B01",
            event: "Training Match",
            site: "Berlin"
        ),
    ]
}
