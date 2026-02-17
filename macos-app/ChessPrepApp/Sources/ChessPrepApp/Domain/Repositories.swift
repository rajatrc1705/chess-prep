import Foundation

enum RepositoryError: Error, LocalizedError, Equatable, Sendable {
    case invalidInput(String)
    case failure(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return message
        case .failure(let message):
            return message
        }
    }
}

protocol GameRepository: Sendable {
    func fetchGames(filter: GameFilter) async throws -> [GameSummary]
}

protocol ImportRepository: Sendable {
    func importPgn(
        dbPath: String,
        pgnPath: String,
        progress: @escaping @Sendable (ImportProgress) -> Void
    ) async throws -> ImportSummary
}
