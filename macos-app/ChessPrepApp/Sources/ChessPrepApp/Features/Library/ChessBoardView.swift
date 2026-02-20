import SwiftUI

struct ChessBoardView: View {
    let fen: String
    let whiteAtBottom: Bool
    let highlightedSquares: Set<String>
    let lastMove: (from: String, to: String)?
    let cellSize: CGFloat

    init(
        fen: String,
        whiteAtBottom: Bool = true,
        highlightedSquares: Set<String> = [],
        lastMove: (from: String, to: String)? = nil,
        cellSize: CGFloat = 46
    ) {
        self.fen = fen
        self.whiteAtBottom = whiteAtBottom
        self.highlightedSquares = highlightedSquares
        self.lastMove = lastMove
        self.cellSize = cellSize
    }

    var body: some View {
        let board = boardMatrix(from: fen)
        let boardSize = cellSize * 8

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

                            ZStack {
                                Rectangle()
                                    .fill(isDark ? explorerDark : explorerLight)
                                    .frame(width: cellSize, height: cellSize)

                                if isHighlighted {
                                    Rectangle()
                                        .fill(Color.yellow.opacity(0.34))
                                        .frame(width: cellSize, height: cellSize)
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
               let from = boardPoint(for: lastMove.from),
               let to = boardPoint(for: lastMove.to) {
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
