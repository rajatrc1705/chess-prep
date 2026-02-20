#if canImport(XCTest)
import Foundation
import XCTest
@testable import ChessPrepApp

@MainActor
final class AppStateTests: XCTestCase {
    func testImportTransitionsToSuccess() async {
        let expected = ImportSummary(total: 40, inserted: 39, skipped: 1, errors: 2, durationMs: 88)

        let state = AppState(
            gameRepository: MockGameRepository(seedGames: []),
            importRepository: MockImportRepository(
                simulatedDelayNanoseconds: 0,
                finalSummary: expected
            ),
            replayRepository: MockReplayRepository()
        )

        state.databasePath = "/tmp/chess-prep.sqlite"
        state.pgnPath = "/tmp/sample.pgn"

        await state.startImport()

        guard case .success(let summary) = state.importState else {
            XCTFail("expected success import state")
            return
        }

        XCTAssertEqual(summary.total, expected.total)
        XCTAssertEqual(summary.inserted, expected.inserted)
        XCTAssertEqual(summary.skipped, expected.skipped)
        XCTAssertEqual(summary.errors, expected.errors)
        XCTAssertGreaterThanOrEqual(summary.durationMs, 0)
        XCTAssertEqual(state.importProgress.total, expected.total)
        XCTAssertEqual(state.importProgress.inserted, expected.inserted)
        XCTAssertEqual(state.importProgress.skipped, expected.skipped)
        XCTAssertEqual(state.importProgress.errors, expected.errors)
    }

    func testSelectedGameTracksSelectedGameID() async throws {
        let state = AppState(
            gameRepository: MockGameRepository(seedGames: MockGameRepository.previewGames),
            importRepository: MockImportRepository(simulatedDelayNanoseconds: 0),
            replayRepository: MockReplayRepository()
        )

        await state.loadGames()

        let candidate = try XCTUnwrap(state.games.dropFirst().first)
        state.selectedGameID = candidate.id

        XCTAssertEqual(state.selectedGame?.id, candidate.id)
    }

    func testLoadGamesAppliesFilterFromState() async {
        let state = AppState(
            gameRepository: MockGameRepository(seedGames: MockGameRepository.previewGames),
            importRepository: MockImportRepository(simulatedDelayNanoseconds: 0),
            replayRepository: MockReplayRepository()
        )

        state.filter.searchText = "Carlsen"
        await state.loadGames()

        XCTAssertFalse(state.games.isEmpty)
        XCTAssertTrue(state.games.allSatisfy {
            "\($0.white) \($0.black) \($0.event) \($0.site)".localizedCaseInsensitiveContains("carlsen")
        })
    }

    func testLoadGamesDoesNotAutoSelectGame() async {
        let state = AppState(
            gameRepository: MockGameRepository(seedGames: MockGameRepository.previewGames),
            importRepository: MockImportRepository(simulatedDelayNanoseconds: 0),
            replayRepository: MockReplayRepository()
        )

        await state.loadGames()

        XCTAssertNil(state.selectedGameID)
        XCTAssertNil(state.selectedGame)
    }

    func testOpenGameExplorerPushesLibraryRouteAndSelectsGame() async throws {
        let state = AppState(
            gameRepository: MockGameRepository(seedGames: MockGameRepository.previewGames),
            importRepository: MockImportRepository(simulatedDelayNanoseconds: 0),
            replayRepository: MockReplayRepository()
        )

        await state.loadGames()
        let candidate = try XCTUnwrap(state.games.dropFirst().first)

        state.openGameExplorer(gameID: candidate.databaseID)

        XCTAssertEqual(state.selectedGameID, candidate.id)
        XCTAssertEqual(state.libraryPath.last, .gameExplorer(candidate.databaseID))
    }
}
#endif
