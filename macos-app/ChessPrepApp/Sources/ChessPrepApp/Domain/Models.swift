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

struct WorkspaceDatabase: Identifiable, Equatable, Sendable {
    let id: UUID
    var label: String
    var path: String
    var isActive: Bool
    var isAvailable: Bool
    var createdAt: Date
    var updatedAt: Date
}

struct GameLocator: Hashable, Sendable {
    let sourceDatabasePath: String
    let databaseID: Int64
}

enum LibraryRoute: Hashable, Sendable {
    case gameExplorer(GameLocator)
}

struct GameSummary: Identifiable, Equatable, Sendable {
    let id: UUID
    let sourceDatabaseID: UUID
    let sourceDatabaseLabel: String
    let sourceDatabasePath: String
    let databaseID: Int64
    let white: String
    let black: String
    let result: String
    let date: String
    let eco: String
    let event: String
    let site: String

    var locator: GameLocator {
        GameLocator(sourceDatabasePath: sourceDatabasePath, databaseID: databaseID)
    }
}

struct GameFilter: Equatable, Sendable {
    var searchText = ""
    var result: GameResultFilter = .any
    var eco = ""
    var eventOrSite = ""
    var dateFrom = ""
    var dateTo = ""

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

        let normalizedDateFrom = dateFrom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedDateFrom.isEmpty && game.date < normalizedDateFrom {
            return false
        }

        let normalizedDateTo = dateTo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalizedDateTo.isEmpty && game.date > normalizedDateTo {
            return false
        }

        return true
    }
}

struct ImportProgress: Equatable, Sendable {
    let total: Int
    let inserted: Int
    let skipped: Int
    let errors: Int

    var completion: Double {
        guard total > 0 else { return 0 }
        return Double(inserted + skipped + errors) / Double(total)
    }
}

struct ImportSummary: Equatable, Sendable {
    let total: Int
    let inserted: Int
    let skipped: Int
    let errors: Int
    let durationMs: Int
}

enum ImportRunState: Equatable, Sendable {
    case idle
    case running
    case success(ImportSummary)
    case failure(String)
}

struct ReplayData: Equatable, Sendable {
    let fens: [String]
    let sans: [String]
    let ucis: [String]
}

struct AnalysisAppliedMove: Equatable, Sendable {
    let san: String
    let uci: String
    let fen: String
}

struct AnalysisNode: Identifiable, Equatable, Sendable {
    let id: UUID
    let parentID: UUID?
    var san: String?
    var uci: String?
    var fen: String
    var comment: String
    var nags: [String]
    var children: [UUID]
}

struct AnalysisWorkspaceNodeRecord: Identifiable, Equatable, Sendable {
    let id: UUID
    let parentID: UUID?
    let san: String?
    let uci: String?
    let fen: String
    let comment: String
    let nags: [String]
    let sortIndex: Int
}

struct AnalysisWorkspaceSummary: Identifiable, Equatable, Sendable {
    let id: Int64
    let sourceDatabasePath: String
    let gameID: Int64
    let name: String
    let rootNodeID: UUID
    let currentNodeID: UUID?
    let createdAt: Date
    let updatedAt: Date
}

struct LoadedAnalysisWorkspace: Equatable, Sendable {
    let workspace: AnalysisWorkspaceSummary
    let nodes: [AnalysisWorkspaceNodeRecord]
}

struct AnalysisPathGraphPoint: Identifiable, Equatable, Sendable {
    let nodeID: UUID
    let ply: Int
    var scoreCp: Int?
    var scoreMate: Int?
    var isEvaluated: Bool

    var id: UUID { nodeID }

    var scoreLabel: String {
        if let mate = scoreMate {
            return "M\(mate)"
        }
        if let cp = scoreCp {
            let pawns = Double(cp) / 100.0
            return String(format: "%+.2f", pawns)
        }
        return "--"
    }

    var plotValue: Double? {
        if let mate = scoreMate {
            return mate >= 0 ? 1300 : -1300
        }
        if let cp = scoreCp {
            return Double(max(min(cp, 1200), -1200))
        }
        return nil
    }
}

struct EngineLine: Identifiable, Equatable, Sendable {
    let multipvRank: Int
    let depth: Int
    let scoreCp: Int?
    let scoreMate: Int?
    let pv: [String]
    let sanPv: [String]

    var id: Int { multipvRank }

    var displayPv: [String] {
        if !sanPv.isEmpty {
            return sanPv
        }
        return pv
    }

    var bestMoveDisplay: String? {
        displayPv.first
    }

    var scoreLabel: String {
        if let mate = scoreMate {
            return "M\(mate)"
        }
        if let cp = scoreCp {
            let pawns = Double(cp) / 100.0
            return String(format: "%+.2f", pawns)
        }
        return "N/A"
    }
}

struct EngineAnalysis: Equatable, Sendable {
    let depth: Int
    let scoreCp: Int?
    let scoreMate: Int?
    let bestMove: String?
    let pv: [String]
    let lines: [EngineLine]

    var scoreLabel: String {
        if let mate = scoreMate {
            return "M\(mate)"
        }
        if let cp = scoreCp {
            let pawns = Double(cp) / 100.0
            return String(format: "%+.2f", pawns)
        }
        return "N/A"
    }

    var displayLines: [EngineLine] {
        if !lines.isEmpty {
            return lines
        }

        return [
            EngineLine(
                multipvRank: 1,
                depth: depth,
                scoreCp: scoreCp,
                scoreMate: scoreMate,
                pv: pv,
                sanPv: []
            ),
        ]
    }
}
