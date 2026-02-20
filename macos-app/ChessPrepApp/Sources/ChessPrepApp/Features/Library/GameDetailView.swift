import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct GameDetailView: View {
    @ObservedObject var state: AppState
    let databaseGameID: Int64?
    @State private var whiteAtBottom = true
    @FocusState private var replayFocused: Bool

    private let boardCellSize: CGFloat = 60
    private let explorerColumnMaxWidth: CGFloat = 1180

    init(state: AppState, databaseGameID: Int64? = nil) {
        self.state = state
        self.databaseGameID = databaseGameID
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Game Explorer")
                    .font(Typography.sectionTitle)
                    .foregroundStyle(Theme.textPrimary)

                if let game = state.selectedGame {
                    metadataBar(for: game)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panelCard()

                    replayBoardPanel
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .panelCard()
                } else {
                    Text("Select a game row from the library to inspect metadata and replay the moves.")
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(maxWidth: explorerColumnMaxWidth, alignment: .leading)
            .padding(20)
        }
        .foregroundStyle(Theme.textPrimary)
        .environment(\.colorScheme, .light)
        .background(Theme.background)
        .focusable()
        .focused($replayFocused)
        .onAppear {
            replayFocused = true
            if let databaseGameID {
                state.selectGame(databaseID: databaseGameID)
                state.reloadReplayForCurrentSelection()
            }
        }
        .onChange(of: databaseGameID) { _, nextID in
            guard let nextID else { return }
            state.selectGame(databaseID: nextID)
            state.reloadReplayForCurrentSelection()
        }
        .onChange(of: state.selectedGameID) { _, _ in
            replayFocused = true
        }
        .onMoveCommand(perform: handleMoveCommand)
    }

    private var boardPixelSize: CGFloat {
        boardCellSize * 8
    }

    private func metadataBar(for game: GameSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(game.white) vs \(game.black)")
                .font(Typography.sectionTitle)

            HStack(spacing: 10) {
                metadataChip(title: "Result", value: game.result, width: 92)
                metadataChip(title: "Date", value: game.date, width: 112)
                metadataChip(title: "ECO", value: game.eco, width: 78)
                metadataChip(title: "Event", value: game.event)
                metadataChip(title: "Site", value: game.site)
            }
        }
    }

    private func metadataChip(title: String, value: String, width: CGFloat? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Typography.detailLabel)
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(Typography.dataMono)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minWidth: width, maxWidth: width ?? .infinity, alignment: .leading)
        .background(Theme.surfaceAlt.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var replayBoardPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Position Explorer")
                    .font(Typography.detailLabel)

                Spacer()

                Button {
                    whiteAtBottom.toggle()
                } label: {
                    Label("Flip", systemImage: "arrow.up.arrow.down.square")
                }
                .buttonStyle(.bordered)
            }

            if state.isLoadingReplay {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading replay...")
                        .font(Typography.body)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if let replayError = state.replayError {
                Text(replayError)
                    .font(Typography.body)
                    .foregroundStyle(Theme.error)
            } else if let currentFen = state.currentFen {
                HStack(alignment: .top, spacing: 18) {
                    ChessBoardView(
                        fen: currentFen,
                        whiteAtBottom: whiteAtBottom,
                        highlightedSquares: highlightedSquares(),
                        lastMove: lastMoveSquares(),
                        cellSize: boardCellSize
                    )
                    .frame(width: boardPixelSize, height: boardPixelSize, alignment: .topLeading)

                    moveListView
                        .frame(minWidth: 380, maxWidth: .infinity, minHeight: boardPixelSize, maxHeight: boardPixelSize, alignment: .topLeading)
                }

                if state.maxPly > 0 {
                    Slider(
                        value: Binding(
                            get: { Double(state.currentPly) },
                            set: { state.setReplayPly(Int($0.rounded())) }
                        ),
                        in: 0...Double(state.maxPly),
                        step: 1
                    )
                    .tint(Theme.accent)
                }

                HStack(spacing: 8) {
                    iconButton(symbol: "backward.end.fill", action: state.goToReplayStart)
                        .disabled(state.currentPly == 0)
                    iconButton(symbol: "chevron.left", action: state.stepBackward)
                        .disabled(!state.canStepBackward)
                    iconButton(
                        symbol: state.isReplayAutoPlaying ? "pause.fill" : "play.fill",
                        prominent: true,
                        action: state.toggleReplayAutoPlay
                    )
                    .disabled(state.maxPly == 0)
                    iconButton(symbol: "chevron.right", action: state.stepForward)
                        .disabled(!state.canStepForward)
                    iconButton(symbol: "forward.end.fill", action: state.goToReplayEnd)
                        .disabled(state.currentPly == state.maxPly)

                    Button("Copy FEN") {
                        state.copyCurrentFenToPasteboard()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Text("Ply \(state.currentPly) / \(state.maxPly)")
                        .font(Typography.dataMono)
                        .foregroundStyle(Theme.textSecondary)
                }

                HStack(spacing: 8) {
                    statusChip(title: "Turn", value: activeColor(from: currentFen))
                    statusChip(title: "Move", value: fullMoveNumber(from: currentFen))
                    statusChip(title: "", value: state.currentMoveSAN ?? "-")
                }

                enginePanel(currentFen: currentFen)
            } else {
                Text("No replay data available for this game yet.")
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func enginePanel(currentFen: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Engine Analysis")
                .font(Typography.detailLabel)

            HStack(spacing: 8) {
                TextField("Engine binary path (e.g. /opt/homebrew/bin/stockfish)", text: $state.enginePath)
                    .textFieldStyle(.roundedBorder)
                    .font(Typography.body)

                Button("Select Engine") {
                    chooseEngineBinary()
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                Stepper(value: $state.engineDepth, in: 1...60) {
                    Text("Depth \(state.engineDepth)")
                        .font(Typography.dataMono)
                }

                Button {
                    Task {
                        await state.analyzeCurrentPosition()
                    }
                } label: {
                    if state.isAnalyzingEngine {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Analyzing...")
                        }
                    } else {
                        Text("Analyze Current Position")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(state.isAnalyzingEngine || currentFen.isEmpty)
            }

            if let engineError = state.engineError {
                Text(engineError)
                    .font(Typography.body)
                    .foregroundStyle(Theme.error)
            }

            if let analysis = state.engineAnalysis {
                HStack(spacing: 8) {
                    statusChip(title: "Depth", value: "\(analysis.depth)")
                    statusChip(title: "Score", value: analysis.scoreLabel)
                    statusChip(title: "Best", value: analysis.bestMove ?? "-")
                }

                if !analysis.pv.isEmpty {
                    Text("PV: \(analysis.pv.joined(separator: " "))")
                        .font(Typography.dataMono)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.top, 6)
    }

    private var moveListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 7) {
                ForEach(0..<((state.replaySans.count + 1) / 2), id: \.self) { turn in
                    let whiteIndex = turn * 2
                    let blackIndex = whiteIndex + 1

                    HStack(spacing: 10) {
                        Text("\(turn + 1).")
                            .font(Typography.dataMono)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 36, alignment: .trailing)

                        moveCell(index: whiteIndex)
                        moveCell(index: blackIndex)
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.surfaceAlt.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border.opacity(0.25), lineWidth: 1)
        )
    }

    private func moveCell(index: Int) -> some View {
        Group {
            if state.replaySans.indices.contains(index) {
                let ply = index + 1
                Button(state.replaySans[index]) {
                    state.setReplayPly(ply)
                }
                .buttonStyle(.plain)
                .font(Typography.dataMono)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .frame(minWidth: 80, alignment: .leading)
                .background(ply == state.currentPly ? Theme.accent.opacity(0.25) : Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(ply == state.currentPly ? Theme.accent : Theme.border.opacity(0.2), lineWidth: 1)
                )
            } else {
                Color.clear
                    .frame(minWidth: 80, maxHeight: 1)
            }
        }
    }

    @ViewBuilder
    private func iconButton(symbol: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        if prominent {
            Button(action: action) {
                Image(systemName: symbol)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        } else {
            Button(action: action) {
                Image(systemName: symbol)
            }
            .buttonStyle(.bordered)
        }
    }

    private func statusChip(title: String, value: String) -> some View {
        HStack(spacing: 4) {
            if !title.isEmpty {
                Text(title)
                    .font(Typography.detailLabel)
                    .foregroundStyle(Theme.textSecondary)
            }
            Text(value)
                .font(Typography.dataMono)
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.surfaceAlt)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func chooseEngineBinary() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.title = "Select UCI Engine Binary"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            state.enginePath = url.path
        }
        #endif
    }

    private func highlightedSquares() -> Set<String> {
        guard state.currentPly > 0 else { return [] }
        let index = state.currentPly - 1
        guard state.replayUcis.indices.contains(index) else { return [] }
        let uci = state.replayUcis[index]
        guard uci.count >= 4 else { return [] }

        let chars = Array(uci)
        let from = String(chars[0...1])
        let to = String(chars[2...3])

        guard isSquareString(from), isSquareString(to) else { return [] }
        return [from, to]
    }

    private func lastMoveSquares() -> (from: String, to: String)? {
        guard state.currentPly > 0 else { return nil }
        let index = state.currentPly - 1
        guard state.replayUcis.indices.contains(index) else { return nil }
        let uci = state.replayUcis[index]
        guard uci.count >= 4 else { return nil }

        let chars = Array(uci)
        let from = String(chars[0...1])
        let to = String(chars[2...3])
        guard isSquareString(from), isSquareString(to) else { return nil }
        return (from, to)
    }

    private func isSquareString(_ value: String) -> Bool {
        guard value.count == 2 else { return false }
        let bytes = Array(value.utf8)
        guard bytes.count == 2 else { return false }
        return (bytes[0] >= 97 && bytes[0] <= 104) && (bytes[1] >= 49 && bytes[1] <= 56)
    }

    private func activeColor(from fen: String) -> String {
        let parts = fen.split(separator: " ")
        guard parts.count > 1 else { return "?" }
        return parts[1] == "w" ? "White" : "Black"
    }

    private func fullMoveNumber(from fen: String) -> String {
        let parts = fen.split(separator: " ")
        guard parts.count > 5 else { return "?" }
        return String(parts[5])
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .left:
            state.stepBackward()
        case .right:
            state.stepForward()
        case .up:
            state.goToReplayStart()
        case .down:
            state.goToReplayEnd()
        default:
            break
        }
    }
}
