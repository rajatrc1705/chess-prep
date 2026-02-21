#if canImport(XCTest)
import Foundation
import XCTest
@testable import ChessPrepApp

@MainActor
final class AppStateTests: XCTestCase {
    private func makeState(
        gameRepository: any GameRepository = MockGameRepository(seedGames: MockGameRepository.previewGames),
        importRepository: any ImportRepository = MockImportRepository(simulatedDelayNanoseconds: 0),
        replayRepository: any ReplayRepository = MockReplayRepository()
    ) -> AppState {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-tests-\(UUID().uuidString).json")
        let store = WorkspaceStore(url: tempURL)
        let state = AppState(
            gameRepository: gameRepository,
            importRepository: importRepository,
            replayRepository: replayRepository,
            workspaceStore: store
        )
        _ = FileManager.default.createFile(atPath: MockGameRepository.previewDatabaseA.path, contents: Data())
        _ = FileManager.default.createFile(atPath: MockGameRepository.previewDatabaseB.path, contents: Data())
        state.workspaceDatabases = [
            MockGameRepository.previewDatabaseA,
            MockGameRepository.previewDatabaseB,
        ]
        state.selectedImportDatabaseID = MockGameRepository.previewDatabaseA.id
        return state
    }

    func testImportTransitionsToSuccess() async {
        let expected = ImportSummary(total: 40, inserted: 39, skipped: 1, errors: 2, durationMs: 88)

        let state = makeState(
            gameRepository: MockGameRepository(seedGames: []),
            importRepository: MockImportRepository(
                simulatedDelayNanoseconds: 0,
                finalSummary: expected
            ),
            replayRepository: MockReplayRepository()
        )
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
        let state = makeState()
        await state.loadGames()

        let candidate = try XCTUnwrap(state.games.dropFirst().first)
        state.selectedGameID = candidate.id

        XCTAssertEqual(state.selectedGame?.id, candidate.id)
    }

    func testLoadGamesAppliesFilterFromState() async {
        let state = makeState()
        state.filter.searchText = "Carlsen"

        await state.loadGames()

        XCTAssertFalse(state.games.isEmpty)
        XCTAssertTrue(state.games.allSatisfy {
            "\($0.white) \($0.black) \($0.event) \($0.site)".localizedCaseInsensitiveContains("carlsen")
        })
    }

    func testLoadGamesDoesNotAutoSelectGame() async {
        let state = makeState()
        await state.loadGames()

        XCTAssertNil(state.selectedGameID)
        XCTAssertNil(state.selectedGame)
    }

    func testOpenGameExplorerPushesLibraryRouteAndSelectsGame() async throws {
        let state = makeState()
        await state.loadGames()
        let candidate = try XCTUnwrap(state.games.dropFirst().first)

        state.openGameExplorer(locator: candidate.locator)

        XCTAssertEqual(state.selectedGameID, candidate.id)
        XCTAssertEqual(state.libraryPath.last, .gameExplorer(candidate.locator))
    }

    func testLoadGamesRespectsActiveDatabaseSelection() async {
        let state = makeState()
        state.workspaceDatabases[0].isActive = false
        state.workspaceDatabases[1].isActive = true

        await state.loadGames()

        XCTAssertFalse(state.games.isEmpty)
        XCTAssertTrue(state.games.allSatisfy { $0.sourceDatabaseID == MockGameRepository.previewDatabaseB.id })
    }
}
#endif
