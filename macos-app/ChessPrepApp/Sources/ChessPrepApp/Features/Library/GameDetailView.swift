import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct GameDetailView: View {
    @ObservedObject var state: AppState
    @State private var whiteAtBottom = true
    @FocusState private var replayFocused: Bool
    private let boardCellSize: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Game Detail")
                .font(Typography.sectionTitle)
                .foregroundStyle(Theme.textPrimary)

            if let game = state.selectedGame {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(game.white) vs \(game.black)")
                        .font(Typography.sectionTitle)

                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            Text("Result")
                                .font(Typography.detailLabel)
                            Text(game.result)
                                .font(Typography.dataMono)
                        }
                        GridRow {
                            Text("Date")
                                .font(Typography.detailLabel)
                            Text(game.date)
                                .font(Typography.dataMono)
                        }
                        GridRow {
                            Text("ECO")
                                .font(Typography.detailLabel)
                            Text(game.eco)
                                .font(Typography.dataMono)
                        }
                        GridRow {
                            Text("Event")
                                .font(Typography.detailLabel)
                            Text(game.event)
                                .font(Typography.body)
                        }
                        GridRow {
                            Text("Site")
                                .font(Typography.detailLabel)
                            Text(game.site)
                                .font(Typography.body)
                        }
                    }
                }
                .panelCard()

                replayBoardPanel
                    .panelCard()
            } else {
                Text("Select a game from the table to inspect metadata and replay the moves.")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Spacer()
        }
        .foregroundStyle(Theme.textPrimary)
        .environment(\.colorScheme, .light)
        .padding(20)
        .background(Theme.background)
        .focusable()
        .focused($replayFocused)
        .onAppear {
            replayFocused = true
        }
        .onChange(of: state.selectedGameID) { _, _ in
            replayFocused = true
        }
        .onMoveCommand(perform: handleMoveCommand)
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
                HStack(alignment: .top, spacing: 14) {
                    boardView(
                        fen: currentFen,
                        whiteAtBottom: whiteAtBottom,
                        highlightedSquares: highlightedSquares(),
                        lastMove: lastMoveSquares()
                    )
                    .frame(maxWidth: 390, alignment: .leading)

                    moveListView
                        .frame(maxWidth: .infinity, minHeight: 300, alignment: .topLeading)
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
                    statusChip(title: "SAN", value: state.currentMoveSAN ?? "-")
                }

                Text(currentFen)
                    .font(Typography.dataMono)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)

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
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(0..<((state.replaySans.count + 1) / 2), id: \.self) { turn in
                    let whiteIndex = turn * 2
                    let blackIndex = whiteIndex + 1

                    HStack(spacing: 8) {
                        Text("\(turn + 1).")
                            .font(Typography.dataMono)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 34, alignment: .trailing)

                        moveCell(index: whiteIndex)
                        moveCell(index: blackIndex)
                    }
                }
            }
        }
        .padding(10)
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
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(minWidth: 62, alignment: .leading)
                .background(ply == state.currentPly ? Theme.accent.opacity(0.25) : Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(ply == state.currentPly ? Theme.accent : Theme.border.opacity(0.2), lineWidth: 1)
                )
            } else {
                Color.clear
                    .frame(minWidth: 62, maxHeight: 1)
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
            Text(title)
                .font(Typography.detailLabel)
                .foregroundStyle(Theme.textSecondary)
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

    private func boardView(
        fen: String,
        whiteAtBottom: Bool,
        highlightedSquares: Set<String>,
        lastMove: (from: String, to: String)?
    ) -> some View {
        let board = boardMatrix(from: fen)
        let boardSize = boardCellSize * 8

        return ZStack {
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { displayRow in
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { displayCol in
                            let boardRank = whiteAtBottom ? displayRow : 7 - displayRow
                            let boardFile = whiteAtBottom ? displayCol : 7 - displayCol
                            let piece = board[boardRank][boardFile]
                            let isDark = (boardRank + boardFile).isMultiple(of: 2)
                            let square = squareName(rankIndex: boardRank, fileIndex: boardFile)
                            let isHighlighted = highlightedSquares.contains(square)

                            ZStack {
                                Rectangle()
                                    .fill(isDark ? explorerDark : explorerLight)
                                    .frame(width: boardCellSize, height: boardCellSize)

                                if isHighlighted {
                                    Rectangle()
                                        .fill(Color.yellow.opacity(0.34))
                                        .frame(width: boardCellSize, height: boardCellSize)
                                }

                                if let piece {
                                    pieceGlyph(for: piece)
                                }
                            }
                        }
                    }
                }
            }

            if let lastMove,
               let from = boardPoint(for: lastMove.from, whiteAtBottom: whiteAtBottom),
               let to = boardPoint(for: lastMove.to, whiteAtBottom: whiteAtBottom) {
                lastMoveArrow(from: from, to: to)
            }
        }
        .frame(width: boardSize, height: boardSize)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(explorerBorder, lineWidth: 1)
        )
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

    private func boardPoint(for square: String, whiteAtBottom: Bool) -> CGPoint? {
        guard square.count == 2 else { return nil }
        let bytes = Array(square.utf8)
        guard bytes.count == 2 else { return nil }

        let file = Int(bytes[0] - 97)
        let rank = Int(bytes[1] - 49)
        guard (0..<8).contains(file), (0..<8).contains(rank) else { return nil }

        let boardRank = 7 - rank
        let boardFile = file

        let displayRow = whiteAtBottom ? boardRank : 7 - boardRank
        let displayCol = whiteAtBottom ? boardFile : 7 - boardFile

        return CGPoint(
            x: CGFloat(displayCol) * boardCellSize + boardCellSize / 2,
            y: CGFloat(displayRow) * boardCellSize + boardCellSize / 2
        )
    }

    private func lastMoveArrow(from: CGPoint, to: CGPoint) -> some View {
        Canvas { context, _ in
            var path = Path()
            path.move(to: from)
            path.addLine(to: to)
            context.stroke(path, with: .color(.yellow.opacity(0.88)), lineWidth: 4)

            let angle = atan2(to.y - from.y, to.x - from.x)
            let headLength: CGFloat = 11
            let left = CGPoint(
                x: to.x - headLength * cos(angle - .pi / 6),
                y: to.y - headLength * sin(angle - .pi / 6)
            )
            let right = CGPoint(
                x: to.x - headLength * cos(angle + .pi / 6),
                y: to.y - headLength * sin(angle + .pi / 6)
            )

            var head = Path()
            head.move(to: to)
            head.addLine(to: left)
            head.addLine(to: right)
            head.closeSubpath()
            context.fill(head, with: .color(.yellow.opacity(0.88)))
        }
    }

    private func isSquareString(_ value: String) -> Bool {
        guard value.count == 2 else { return false }
        let bytes = Array(value.utf8)
        guard bytes.count == 2 else { return false }
        return (bytes[0] >= 97 && bytes[0] <= 104) && (bytes[1] >= 49 && bytes[1] <= 56)
    }

    private func squareName(rankIndex: Int, fileIndex: Int) -> String {
        let fileUnicode = UnicodeScalar(97 + fileIndex) ?? UnicodeScalar(97)!
        let rank = 8 - rankIndex
        return "\(Character(fileUnicode))\(rank)"
    }

    private func boardMatrix(from fen: String) -> [[Character?]] {
        let boardPart = fen.split(separator: " ").first.map(String.init) ?? ""
        let ranks = boardPart.split(separator: "/", omittingEmptySubsequences: false)
        guard ranks.count == 8 else {
            return Array(repeating: Array(repeating: nil, count: 8), count: 8)
        }

        return ranks.map { rank in
            var row: [Character?] = []
            for char in rank {
                if let emptyCount = char.wholeNumberValue {
                    row.append(contentsOf: Array(repeating: nil, count: emptyCount))
                } else {
                    row.append(char)
                }
            }

            if row.count < 8 {
                row.append(contentsOf: Array(repeating: nil, count: 8 - row.count))
            }
            return Array(row.prefix(8))
        }
    }

    private func symbol(for piece: Character) -> String {
        switch piece {
        // Use the filled glyph set for both sides; color differentiates white/black.
        case "K": return "♚"
        case "Q": return "♛"
        case "R": return "♜"
        case "B": return "♝"
        case "N": return "♞"
        case "P": return "♟"
        case "k": return "♚"
        case "q": return "♛"
        case "r": return "♜"
        case "b": return "♝"
        case "n": return "♞"
        case "p": return "♟"
        default: return ""
        }
    }

    private var explorerDark: Color {
        Color(red: 0.36, green: 0.24, blue: 0.16)
    }

    private var explorerLight: Color {
        Color(red: 0.84, green: 0.73, blue: 0.57)
    }

    private var explorerBorder: Color {
        Color(red: 0.23, green: 0.15, blue: 0.10).opacity(0.85)
    }

    @ViewBuilder
    private func pieceGlyph(for piece: Character) -> some View {
        let glyph = symbol(for: piece)
        let pieceFont = Font.system(size: 31)

        if piece.isUppercase {
            let offsets: [CGSize] = [
                CGSize(width: -0.7, height: 0),
                CGSize(width: 0.7, height: 0),
                CGSize(width: 0, height: -0.7),
                CGSize(width: 0, height: 0.7),
            ]

            ZStack {
                ForEach(Array(offsets.enumerated()), id: \.offset) { _, offset in
                    Text(glyph)
                        .font(pieceFont)
                        .foregroundStyle(Color.black.opacity(0.95))
                        .offset(x: offset.width, y: offset.height)
                }

                Text(glyph)
                    .font(pieceFont)
                    .foregroundStyle(Color(red: 0.95, green: 0.94, blue: 0.90))
            }
        } else {
            Text(glyph)
                .font(pieceFont)
                .foregroundStyle(Color.black)
        }
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
