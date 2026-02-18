import Foundation

struct MockEngineRepository: EngineRepository {
    var simulatedDelayNanoseconds: UInt64 = 180_000_000

    func analyzePosition(enginePath: String, fen: String, depth: Int) async throws -> EngineAnalysis {
        let cleanPath = enginePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanFen = fen.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanPath.isEmpty else {
            throw RepositoryError.invalidInput("Engine path is required.")
        }
        guard !cleanFen.isEmpty else {
            throw RepositoryError.invalidInput("FEN is required.")
        }

        try await Task.sleep(nanoseconds: simulatedDelayNanoseconds)

        return EngineAnalysis(
            depth: max(depth, 1),
            scoreCp: 34,
            scoreMate: nil,
            bestMove: "e2e4",
            pv: ["e2e4", "e7e5", "g1f3", "b8c6"]
        )
    }
}
