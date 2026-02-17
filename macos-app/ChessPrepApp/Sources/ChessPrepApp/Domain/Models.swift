import Foundation

enum AppSection: String, CaseIterable, Identifiable, Sendable {
    case importPgn
    case library

    var id: String { rawValue }

    var title: String {
        switch self {
        case .importPgn:
            return "Import"
        case .library:
            return "Library"
        }
    }

    var systemImage: String {
        switch self {
        case .importPgn:
            return "square.and.arrow.down"
        case .library:
            return "books.vertical"
        }
    }
}

enum GameResultFilter: String, CaseIterable, Identifiable, Sendable {
    case any = "Any"
    case whiteWin = "1-0"
    case blackWin = "0-1"
    case draw = "1/2-1/2"

    var id: String { rawValue }
}

struct GameSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let white: String
    let black: String
    let result: String
    let date: String
    let eco: String
    let event: String
    let site: String
}

struct GameFilter: Equatable, Sendable {
    var searchText = ""
    var result: GameResultFilter = .any
    var eco = ""
    var eventOrSite = ""

    func matches(_ game: GameSummary) -> Bool {
        let normalizedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedSearch.isEmpty {
            let haystack = [game.white, game.black, game.event, game.site]
                .joined(separator: " ")
                .lowercased()
            if !haystack.contains(normalizedSearch) {
                return false
            }
        }

        if result != .any && game.result != result.rawValue {
            return false
        }

        let normalizedEco = eco.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedEco.isEmpty && !game.eco.lowercased().contains(normalizedEco) {
            return false
        }

        let normalizedEventOrSite = eventOrSite.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedEventOrSite.isEmpty {
            let eventSite = "\(game.event) \(game.site)".lowercased()
            if !eventSite.contains(normalizedEventOrSite) {
                return false
            }
        }

        return true
    }
}

struct ImportProgress: Equatable, Sendable {
    let total: Int
    let inserted: Int
    let skipped: Int

    var completion: Double {
        guard total > 0 else { return 0 }
        return Double(inserted + skipped) / Double(total)
    }
}

struct ImportSummary: Equatable, Sendable {
    let total: Int
    let inserted: Int
    let skipped: Int
    let durationMs: Int
}

enum ImportRunState: Equatable, Sendable {
    case idle
    case running
    case success(ImportSummary)
    case failure(String)
}
