import Foundation

struct MockReplayRepository: ReplayRepository {
    let replayByGameID: [Int64: ReplayData]

    init(replayByGameID: [Int64: ReplayData] = [:]) {
        self.replayByGameID = replayByGameID
    }

    func fetchReplay(dbPath: String, gameID: Int64) async throws -> ReplayData {
        let cleanDbPath = dbPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDbPath.isEmpty else {
            throw RepositoryError.invalidInput("Database path is required.")
        }

        if let replay = replayByGameID[gameID], !replay.fens.isEmpty {
            return replay
        }

        return ReplayData(
            fens: [
                "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
                "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1",
                "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
            ],
            sans: ["e4", "e5"],
            ucis: ["e2e4", "e7e5"]
        )
    }
}
