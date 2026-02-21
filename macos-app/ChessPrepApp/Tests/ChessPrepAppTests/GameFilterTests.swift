#if canImport(XCTest)
import Foundation
import XCTest
@testable import ChessPrepApp

final class GameFilterTests: XCTestCase {
    func testFilterMatchesCompositeCriteria() {
        let game = GameSummary(
            id: UUID(),
            sourceDatabaseID: UUID(),
            sourceDatabaseLabel: "Main",
            sourceDatabasePath: "/tmp/main.sqlite",
            databaseID: 1,
            white: "Alice",
            black: "Bob",
            result: "1-0",
            date: "2024.01.01",
            eco: "C20",
            event: "Weekend Cup",
            site: "Berlin"
        )

        var filter = GameFilter()
        filter.searchText = "alice"
        filter.result = .whiteWin
        filter.eco = "C2"
        filter.eventOrSite = "berlin"

        XCTAssertTrue(filter.matches(game))
    }

    func testFilterRejectsOnMismatchedResult() {
        let game = GameSummary(
            id: UUID(),
            sourceDatabaseID: UUID(),
            sourceDatabaseLabel: "Main",
            sourceDatabasePath: "/tmp/main.sqlite",
            databaseID: 2,
            white: "Carol",
            black: "Dave",
            result: "0-1",
            date: "2024.01.02",
            eco: "B01",
            event: "Training",
            site: "Paris"
        )

        var filter = GameFilter()
        filter.result = .draw

        XCTAssertFalse(filter.matches(game))
    }

    func testFilterMatchesWithinDateRange() {
        let game = GameSummary(
            id: UUID(),
            sourceDatabaseID: UUID(),
            sourceDatabaseLabel: "Main",
            sourceDatabasePath: "/tmp/main.sqlite",
            databaseID: 3,
            white: "Eve",
            black: "Frank",
            result: "1-0",
            date: "2024.06.15",
            eco: "C42",
            event: "Open",
            site: "Madrid"
        )

        var filter = GameFilter()
        filter.dateFrom = "2024.01.01"
        filter.dateTo = "2024.12.31"

        XCTAssertTrue(filter.matches(game))
    }

    func testFilterRejectsBeforeDateFrom() {
        let game = GameSummary(
            id: UUID(),
            sourceDatabaseID: UUID(),
            sourceDatabaseLabel: "Main",
            sourceDatabasePath: "/tmp/main.sqlite",
            databaseID: 4,
            white: "Gina",
            black: "Hank",
            result: "0-1",
            date: "2023.12.31",
            eco: "B90",
            event: "Qualifier",
            site: "Rome"
        )

        var filter = GameFilter()
        filter.dateFrom = "2024.01.01"

        XCTAssertFalse(filter.matches(game))
    }

    func testFilterRejectsAfterDateTo() {
        let game = GameSummary(
            id: UUID(),
            sourceDatabaseID: UUID(),
            sourceDatabaseLabel: "Main",
            sourceDatabasePath: "/tmp/main.sqlite",
            databaseID: 5,
            white: "Ivy",
            black: "Jack",
            result: "1/2-1/2",
            date: "2025.01.01",
            eco: "D30",
            event: "Masters",
            site: "Prague"
        )

        var filter = GameFilter()
        filter.dateTo = "2024.12.31"

        XCTAssertFalse(filter.matches(game))
    }
}
#endif
