import SwiftUI

struct ChessBoardView: View {
    let fen: String
    let whiteAtBottom: Bool
    let highlightedSquares: Set<String>
    let lastMove: (from: String, to: String)?
    let legalMovesByFrom: [String: [String: String]]
    let moveAnnotationBadge: (symbol: String, color: Color)?
    let cellSize: CGFloat
    let onMoveAttempt: ((String) -> Void)?

    @State private var dragStartSquare: String?
    @State private var dragCurrentSquare: String?
    @State private var dragPiece: Character?
    @State private var dragLocation: CGPoint?
    @State private var selectedSquare: String?

    init(
        fen: String,
        whiteAtBottom: Bool = true,
        highlightedSquares: Set<String> = [],
        lastMove: (from: String, to: String)? = nil,
        legalMovesByFrom: [String: [String: String]] = [:],
        moveAnnotationBadge: (symbol: String, color: Color)? = nil,
        cellSize: CGFloat = 46,
        onMoveAttempt: ((String) -> Void)? = nil
    ) {
        self.fen = fen
        self.whiteAtBottom = whiteAtBottom
        self.highlightedSquares = highlightedSquares
        self.lastMove = lastMove
        self.legalMovesByFrom = legalMovesByFrom
        self.moveAnnotationBadge = moveAnnotationBadge
        self.cellSize = cellSize
        self.onMoveAttempt = onMoveAttempt
    }

    var body: some View {
        let board = boardMatrix(from: fen)
        let boardSize = cellSize * 8
        let dragHighlights = Set([dragStartSquare, dragCurrentSquare].compactMap { $0 })
        let selectedTargets = selectedSquare.map { legalTargets(from: $0) } ?? []
        let dragTargets = dragStartSquare.map { legalTargets(from: $0) } ?? []

        ZStack {
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
                                || dragHighlights.contains(square)
                                || selectedSquare == square
                                || selectedTargets.contains(square)
                                || dragTargets.contains(square)
                            let hidePiece = dragStartSquare == square && dragPiece != nil

                            ZStack {
                                Rectangle()
                                    .fill(isDark ? explorerDark : explorerLight)
                                    .frame(width: cellSize, height: cellSize)

                                if isHighlighted {
                                    Rectangle()
                                        .fill(Color.yellow.opacity(0.34))
                                        .frame(width: cellSize, height: cellSize)
                                }

                                if let piece, !hidePiece {
                                    pieceGlyph(for: piece)
                                }
                            }
                        }
                    }
                }
            }

            if let lastMove,
               let from = boardPoint(for: lastMove.from),
               let to = boardPoint(for: lastMove.to) {
                lastMoveArrow(from: from, to: to)

                if let moveAnnotationBadge {
                    boardAnnotationBadge(
                        symbol: moveAnnotationBadge.symbol,
                        color: moveAnnotationBadge.color,
                        destination: to
                    )
                }
            }

            if let dragPiece, let dragLocation {
                pieceGlyph(for: dragPiece)
                    .position(dragLocation)
                    .allowsHitTesting(false)
                    .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)
            }
        }
        .frame(width: boardSize, height: boardSize)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(explorerBorder, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .gesture(dragGesture(board: board, boardSize: boardSize))
        .simultaneousGesture(tapGesture(board: board, boardSize: boardSize))
        .onChange(of: fen) { _, _ in
            clearDragState()
            clearSelection()
        }
    }

    private func dragGesture(board: [[Character?]], boardSize: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard onMoveAttempt != nil else { return }

                if dragStartSquare == nil {
                    guard let start = squareName(at: value.startLocation, boardSize: boardSize),
                          let piece = piece(at: start, board: board),
                          isPieceDraggable(piece) else {
                        return
                    }
                    dragStartSquare = start
                    dragCurrentSquare = start
                    dragPiece = piece
                    selectedSquare = start
                }

                dragCurrentSquare = squareName(at: value.location, boardSize: boardSize)
                dragLocation = clampedPoint(value.location, boardSize: boardSize)
            }
            .onEnded { value in
                defer { clearDragState() }
                guard onMoveAttempt != nil else { return }
                guard let from = dragStartSquare,
                      let to = squareName(at: value.location, boardSize: boardSize),
                      from != to,
                      let uci = legalMove(from: from, to: to) else {
                    return
                }

                clearSelection()
                onMoveAttempt?(uci)
            }
    }

    private func tapGesture(board: [[Character?]], boardSize: CGFloat) -> some Gesture {
        SpatialTapGesture()
            .onEnded { value in
                guard onMoveAttempt != nil else { return }
                handleTap(at: value.location, board: board, boardSize: boardSize)
            }
    }

    private func handleTap(at location: CGPoint, board: [[Character?]], boardSize: CGFloat) {
        guard let tappedSquare = squareName(at: location, boardSize: boardSize) else {
            clearSelection()
            return
        }

        if let selectedSquare {
            if selectedSquare == tappedSquare {
                clearSelection()
                return
            }

            if let uci = legalMove(from: selectedSquare, to: tappedSquare) {
                clearSelection()
                onMoveAttempt?(uci)
                return
            }
        }

        guard let tappedPiece = piece(at: tappedSquare, board: board),
              isPieceDraggable(tappedPiece),
              !legalTargets(from: tappedSquare).isEmpty else {
            clearSelection()
            return
        }

        self.selectedSquare = tappedSquare
    }

    private func clearDragState() {
        dragStartSquare = nil
        dragCurrentSquare = nil
        dragPiece = nil
        dragLocation = nil
    }

    private func clearSelection() {
        selectedSquare = nil
    }

    private func legalTargets(from square: String) -> Set<String> {
        guard let destinations = legalMovesByFrom[square] else { return [] }
        return Set(destinations.keys)
    }

    private func legalMove(from: String, to: String) -> String? {
        legalMovesByFrom[from]?[to]
    }

    private func clampedPoint(_ point: CGPoint, boardSize: CGFloat) -> CGPoint {
        CGPoint(
            x: min(max(point.x, 0), boardSize),
            y: min(max(point.y, 0), boardSize)
        )
    }

    private func squareName(at point: CGPoint, boardSize: CGFloat) -> String? {
        guard point.x >= 0, point.y >= 0, point.x < boardSize, point.y < boardSize else {
            return nil
        }

        let displayCol = Int(point.x / cellSize)
        let displayRow = Int(point.y / cellSize)
        guard (0..<8).contains(displayCol), (0..<8).contains(displayRow) else {
            return nil
        }

        let boardRank = whiteAtBottom ? displayRow : 7 - displayRow
        let boardFile = whiteAtBottom ? displayCol : 7 - displayCol
        return squareName(rankIndex: boardRank, fileIndex: boardFile)
    }

    private func piece(at square: String, board: [[Character?]]) -> Character? {
        guard square.count == 2 else { return nil }
        let bytes = Array(square.utf8)
        guard bytes.count == 2 else { return nil }

        let file = Int(bytes[0]) - 97
        let rank = Int(bytes[1]) - 48
        let boardRank = 8 - rank
        guard (0..<8).contains(file), (0..<8).contains(boardRank) else {
            return nil
        }

        return board[boardRank][file]
    }

    private func isPieceDraggable(_ piece: Character) -> Bool {
        guard let side = activeSide() else { return true }
        if side == "w" {
            return piece.isUppercase
        }
        return piece.isLowercase
    }

    private func activeSide() -> Character? {
        let parts = fen.split(separator: " ")
        guard parts.count > 1 else { return nil }
        guard let side = parts[1].first, (side == "w" || side == "b") else { return nil }
        return side
    }

    private func boardPoint(for square: String) -> CGPoint? {
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
            x: CGFloat(displayCol) * cellSize + cellSize / 2,
            y: CGFloat(displayRow) * cellSize + cellSize / 2
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

    private func boardAnnotationBadge(symbol: String, color: Color, destination: CGPoint) -> some View {
        Text(symbol)
            .font(.system(size: max(11, cellSize * 0.24), weight: .bold, design: .rounded))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(color.opacity(0.95))
            )
            .overlay(
                Capsule()
                    .stroke(Color.black.opacity(0.2), lineWidth: 1)
            )
            .position(
                x: destination.x + cellSize * 0.28,
                y: destination.y - cellSize * 0.30
            )
            .allowsHitTesting(false)
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
        let pieceFont = Font.system(size: cellSize * 0.67)

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
}
