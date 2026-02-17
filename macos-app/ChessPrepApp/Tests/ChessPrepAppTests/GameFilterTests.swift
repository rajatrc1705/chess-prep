#if canImport(XCTest)
import Foundation
import XCTest
@testable import ChessPrepApp

final class GameFilterTests: XCTestCase {
    func testFilterMatchesCompositeCriteria() {
        let game = GameSummary(
            id: UUID(),
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
}
#endif
