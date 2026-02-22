import Foundation

struct MockEngineRepository: EngineRepository {
    var simulatedDelayNanoseconds: UInt64 = 180_000_000

    func analyzePosition(enginePath: String, fen: String, depth: Int, multipv: Int) async throws -> EngineAnalysis {
        let cleanPath = enginePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFen = fen.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanPath.isEmpty else {
            throw RepositoryError.invalidInput("Engine path is required.")
        }
        guard !cleanFen.isEmpty else {
            throw RepositoryError.invalidInput("FEN is required.")
        }

        try await Task.sleep(nanoseconds: simulatedDelayNanoseconds)

        let safeMultiPv = max(1, min(multipv, 3))
        let allLines = [
            EngineLine(
                multipvRank: 1,
                depth: max(depth, 1),
                scoreCp: 34,
                scoreMate: nil,
                pv: ["e2e4", "e7e5", "g1f3", "b8c6"],
                sanPv: ["e4", "e5", "Nf3", "Nc6"]
            ),
            EngineLine(
                multipvRank: 2,
                depth: max(depth, 1),
                scoreCp: 22,
                scoreMate: nil,
                pv: ["d2d4", "d7d5", "c2c4"],
                sanPv: ["d4", "d5", "c4"]
            ),
            EngineLine(
                multipvRank: 3,
                depth: max(depth, 1),
                scoreCp: 10,
                scoreMate: nil,
                pv: ["g1f3", "d7d5", "d2d4"],
                sanPv: ["Nf3", "d5", "d4"]
            ),
        ]
        let lines = Array(allLines.prefix(safeMultiPv))

        return EngineAnalysis(
            depth: max(depth, 1),
            scoreCp: 34,
            scoreMate: nil,
            bestMove: "e4",
            pv: ["e2e4", "e7e5", "g1f3", "b8c6"],
            lines: lines
        )
    }
}
