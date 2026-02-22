#if canImport(XCTest)
import Foundation
import XCTest
@testable import ChessPrepApp

@MainActor
final class AppStateTests: XCTestCase {
    private func makeState(
        gameRepository: any GameRepository = MockGameRepository(seedGames: MockGameRepository.previewGames),
        importRepository: any ImportRepository = MockImportRepository(simulatedDelayNanoseconds: 0),
        replayRepository: any ReplayRepository = MockReplayRepository(),
        engineRepository: any EngineRepository = MockEngineRepository(simulatedDelayNanoseconds: 0),
        analysisRepository: any AnalysisRepository = MockAnalysisRepository(simulatedDelayNanoseconds: 0)
    ) -> AppState {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("workspace-tests-\(UUID().uuidString).json")
        let store = WorkspaceStore(url: tempURL)
        let state = AppState(
            gameRepository: gameRepository,
            importRepository: importRepository,
            replayRepository: replayRepository,
            engineRepository: engineRepository,
            analysisRepository: analysisRepository,
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

    func testRebuildAnalysisTreeFromReplayBuildsMainline() throws {
        let state = makeState()
        state.replayFens = [
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1",
            "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
        ]
        state.replaySans = ["e4", "e5"]
        state.replayUcis = ["e2e4", "e7e5"]
        state.currentPly = 1

        state.rebuildAnalysisTreeFromReplay()

        let rootID = try XCTUnwrap(state.analysisRootNodeID)
        XCTAssertEqual(state.analysisNodeIDByPly.count, 3)
        XCTAssertEqual(state.analysisNodesByID.count, 3)
        XCTAssertEqual(state.currentAnalysisNodeID, state.analysisNodeIDByPly[1])

        let rootNode = try XCTUnwrap(state.analysisNodesByID[rootID])
        XCTAssertEqual(rootNode.fen, state.replayFens[0])
        XCTAssertEqual(rootNode.children.count, 1)

        let firstChildID = try XCTUnwrap(rootNode.children.first)
        let firstChild = try XCTUnwrap(state.analysisNodesByID[firstChildID])
        XCTAssertEqual(firstChild.parentID, rootID)
        XCTAssertEqual(firstChild.san, "e4")
        XCTAssertEqual(firstChild.uci, "e2e4")
    }

    func testReplayNavigationKeepsAnalysisSelectionInSync() throws {
        let state = makeState()
        state.replayFens = [
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1",
            "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
        ]
        state.replaySans = ["e4", "e5"]
        state.replayUcis = ["e2e4", "e7e5"]
        state.rebuildAnalysisTreeFromReplay()

        state.goToReplayEnd()
        XCTAssertEqual(state.currentPly, 2)
        XCTAssertEqual(state.currentAnalysisNodeID, state.analysisNodeIDByPly[2])

        state.stepBackward()
        XCTAssertEqual(state.currentPly, 1)
        XCTAssertEqual(state.currentAnalysisNodeID, state.analysisNodeIDByPly[1])

        state.goToReplayStart()
        XCTAssertEqual(state.currentPly, 0)
        XCTAssertEqual(state.currentAnalysisNodeID, state.analysisNodeIDByPly[0])
    }

    func testAddAnalysisMoveReusesExistingVariationByUci() async throws {
        let state = makeState(analysisRepository: MockAnalysisRepository(simulatedDelayNanoseconds: 0))
        state.replayFens = ["rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"]
        state.rebuildAnalysisTreeFromReplay()

        let rootID = try XCTUnwrap(state.analysisRootNodeID)
        state.selectAnalysisNode(id: rootID)

        await state.addAnalysisMove(uci: "e2e4")
        let firstChildID = try XCTUnwrap(state.currentAnalysisNodeID)
        let rootAfterFirstInsert = try XCTUnwrap(state.analysisNodesByID[rootID])
        XCTAssertEqual(rootAfterFirstInsert.children.count, 1)

        state.selectAnalysisNode(id: rootID)
        await state.addAnalysisMove(uci: "e2e4")
        let rootAfterSecondInsert = try XCTUnwrap(state.analysisNodesByID[rootID])
        XCTAssertEqual(rootAfterSecondInsert.children.count, 1)
        XCTAssertEqual(state.currentAnalysisNodeID, firstChildID)
    }

    func testApplyAnalysisMoveFromInputClearsInputOnSuccess() async throws {
        let state = makeState(analysisRepository: MockAnalysisRepository(simulatedDelayNanoseconds: 0))
        state.replayFens = ["rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"]
        state.rebuildAnalysisTreeFromReplay()
        state.analysisMoveInput = "e2e4"

        await state.applyAnalysisMoveFromInput()

        XCTAssertEqual(state.analysisMoveInput, "")
        XCTAssertNil(state.analysisError)
        XCTAssertEqual(state.currentAnalysisNode?.uci, "e2e4")
    }

    func testUpdateCommentAndToggleNagMutateCurrentNode() async throws {
        let state = makeState(analysisRepository: MockAnalysisRepository(simulatedDelayNanoseconds: 0))
        state.replayFens = ["rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"]
        state.rebuildAnalysisTreeFromReplay()
        await state.addAnalysisMove(uci: "e2e4")

        state.updateCurrentAnalysisComment("Practical prep line.")
        state.toggleCurrentAnalysisNag("!")
        state.toggleCurrentAnalysisNag("!?")
        state.toggleCurrentAnalysisNag("!")

        XCTAssertEqual(state.currentAnalysisNode?.comment, "Practical prep line.")
        XCTAssertEqual(state.currentAnalysisNode?.nags, ["!?"])
    }

    func testStepBackwardFollowsVariationParentBeforeMainline() async throws {
        let state = makeState(analysisRepository: MockAnalysisRepository(simulatedDelayNanoseconds: 0))
        state.replayFens = [
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1",
            "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2",
        ]
        state.replaySans = ["e4", "e5"]
        state.replayUcis = ["e2e4", "e7e5"]
        state.rebuildAnalysisTreeFromReplay()

        state.setReplayPly(1) // Select mainline move e4.
        await state.addAnalysisMove(uci: "c7c5")
        let variationBlackID = try XCTUnwrap(state.currentAnalysisNodeID)
        await state.addAnalysisMove(uci: "g1f3")
        let variationWhiteID = try XCTUnwrap(state.currentAnalysisNodeID)

        XCTAssertNotEqual(variationWhiteID, state.analysisNodeIDByPly[2])

        state.stepBackward()
        XCTAssertEqual(state.currentAnalysisNodeID, variationBlackID)

        state.stepBackward()
        XCTAssertEqual(state.currentAnalysisNodeID, state.analysisNodeIDByPly[1])

        state.stepBackward()
        XCTAssertEqual(state.currentAnalysisNodeID, state.analysisNodeIDByPly[0])
    }
}
#endif
