import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct GameDetailView: View {
    @ObservedObject var state: AppState
    let locator: GameLocator?
    @State private var whiteAtBottom = true
    @State private var collapsedAnalysisNodeIDs: Set<UUID> = []
    @State private var legalMoveLookupBySource: [String: [String: String]] = [:]
    @State private var editingAnnotationNodeID: UUID?
    @FocusState private var inlineAnnotationFocusID: UUID?
    @FocusState private var replayFocused: Bool

    private let boardCellSize: CGFloat = 60
    private let explorerColumnMaxWidth: CGFloat = 1180
    private let annotationSymbolOptions: [String] = [
        "!!", "!", "!?", "?!",
        "?", "??", "x", "+-",
        "+/-", "-/+", "=", "inf",
        "-+", "=/inf",
    ]

    private struct AnalysisDisplayLine: Identifiable {
        let id: UUID
        let rootNodeID: UUID
        let nodeIDs: [UUID]
        let depth: Int
        let isVariation: Bool
        let hasNestedVariations: Bool
    }

    private struct LineToken {
        let nodeID: UUID
        let moveCore: String
        let nags: String
        let annotation: String
    }

    init(state: AppState, locator: GameLocator? = nil) {
        self.state = state
        self.locator = locator
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
            if let locator {
                state.selectGame(locator: locator)
                state.reloadReplayForCurrentSelection()
            }
        }
        .onChange(of: locator) { _, nextLocator in
            guard let nextLocator else { return }
            state.selectGame(locator: nextLocator)
            state.reloadReplayForCurrentSelection()
        }
        .onChange(of: state.selectedGameID) { _, _ in
            replayFocused = true
            collapsedAnalysisNodeIDs = []
            legalMoveLookupBySource = [:]
            editingAnnotationNodeID = nil
            inlineAnnotationFocusID = nil
        }
        .onChange(of: state.currentAnalysisNodeID) { _, _ in
            expandSelectedAnalysisPath()
        }
        .onChange(of: inlineAnnotationFocusID) { _, nextFocus in
            if nextFocus == nil {
                editingAnnotationNodeID = nil
            }
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
                metadataChip(title: "DB", value: game.sourceDatabaseLabel, width: 126)
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
            } else if let replayFen = state.currentFen {
                let boardFen = state.currentAnalysisFen ?? replayFen
                HStack(alignment: .top, spacing: 18) {
                    ChessBoardView(
                        fen: boardFen,
                        whiteAtBottom: whiteAtBottom,
                        highlightedSquares: highlightedSquares(),
                        lastMove: lastMoveSquares(),
                        legalMovesByFrom: legalMoveLookupBySource,
                        moveAnnotationBadge: activeMoveAnnotationBadge(),
                        cellSize: boardCellSize,
                        onMoveAttempt: { uci in
                            Task {
                                await state.addAnalysisMove(uci: uci)
                            }
                        }
                    )
                    .frame(width: boardPixelSize, height: boardPixelSize, alignment: .topLeading)
                    .task(id: boardFen) {
                        await refreshLegalMoveLookup(for: boardFen)
                    }

                    analysisMoveListView
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
                    statusChip(title: "Turn", value: activeColor(from: boardFen))
                    statusChip(title: "Move", value: fullMoveNumber(from: boardFen))
                    statusChip(title: "Node", value: state.currentAnalysisNode?.san ?? "Start")
                }

                if !isCurrentAnalysisOnReplayMainline {
                    Text("Viewing analysis variation from replay ply \(state.currentPly).")
                        .font(Typography.detailLabel)
                        .foregroundStyle(Theme.textSecondary)
                }

                enginePanel(currentFen: boardFen)
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

    private var analysisMoveListView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Move Tree")
                        .font(Typography.detailLabel)
                        .foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Button("Collapse All") {
                        collapseAllVariations()
                    }
                    .buttonStyle(.bordered)
                    .font(Typography.detailLabel)

                    Button("Expand All") {
                        collapsedAnalysisNodeIDs.removeAll()
                    }
                    .buttonStyle(.bordered)
                    .font(Typography.detailLabel)
                }

                Divider()

                if analysisDisplayLines.isEmpty {
                    Text("No moves in analysis yet. Drag a piece on the board to start a line.")
                        .font(Typography.detailLabel)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(analysisDisplayLines) { line in
                        analysisDisplayLineView(line)
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

    private func analysisDisplayLineView(_ line: AnalysisDisplayLine) -> some View {
        let isCollapsed = collapsedAnalysisNodeIDs.contains(line.rootNodeID)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Color.clear
                    .frame(width: CGFloat(line.depth) * 18)

                if line.hasNestedVariations {
                    Button {
                        toggleCollapsed(id: line.rootNodeID)
                    } label: {
                        Image(systemName: isCollapsed ? "plus.square.fill" : "minus.square.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .frame(width: 14, alignment: .center)
                } else {
                    Image(systemName: line.isVariation ? "arrow.turn.down.right" : "circle.fill")
                        .font(.system(size: line.isVariation ? 10 : 4, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary.opacity(0.75))
                        .frame(width: 14, alignment: .center)
                }

                if !line.isVariation {
                    Text("main")
                        .font(Typography.detailLabel)
                        .foregroundStyle(Theme.textSecondary)
                }

                Button {
                    selectAnalysisNodeFromMoveList(line.rootNodeID)
                } label: {
                    Text(lineAttributedString(for: line))
                        .font(Typography.dataMono)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Annotate") {
                        annotateMove(line.rootNodeID)
                    }

                    Button("Delete Move", role: .destructive) {
                        state.deleteAnalysisNode(id: line.rootNodeID)
                    }
                    .disabled(!canDeleteMove(line.rootNodeID))

                    Divider()

                    ForEach(annotationSymbolOptions, id: \.self) { symbol in
                        Button {
                            applyAnnotationSymbol(symbol, to: line.rootNodeID)
                        } label: {
                            if isAnnotationSymbolSelected(symbol, on: line.rootNodeID) {
                                Label(symbol, systemImage: "checkmark")
                            } else {
                                Text(symbol)
                            }
                        }
                    }
                }
            }

            if editingAnnotationNodeID == line.rootNodeID {
                inlineAnnotationEditor(
                    nodeID: line.rootNodeID,
                    depth: line.depth,
                    isVariation: line.isVariation
                )
            }
        }
    }

    private func inlineAnnotationEditor(nodeID: UUID, depth: Int, isVariation: Bool) -> some View {
        let columns = Array(repeating: GridItem(.fixed(38), spacing: 6), count: 4)

        return VStack(alignment: .leading, spacing: 8) {
            TextField(
                "Comment for this move",
                text: annotationCommentBinding(for: nodeID),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .font(Typography.body)
            .focused($inlineAnnotationFocusID, equals: nodeID)
            .submitLabel(.done)
            .onSubmit {
                closeInlineAnnotationEditor()
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(annotationSymbolOptions, id: \.self) { symbol in
                    Button(symbol) {
                        applyAnnotationSymbol(symbol, to: nodeID)
                    }
                    .buttonStyle(.plain)
                    .font(Typography.dataMono)
                    .frame(width: 38, height: 26)
                    .background(
                        isAnnotationSymbolSelected(symbol, on: nodeID)
                            ? Theme.accent.opacity(0.22)
                            : Theme.surface
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                isAnnotationSymbolSelected(symbol, on: nodeID)
                                    ? Theme.accent
                                    : Theme.border.opacity(0.3),
                                lineWidth: 1
                            )
                    )
                }
            }
        }
        .padding(.leading, CGFloat(depth) * 18 + (isVariation ? 26 : 58))
        .padding(.trailing, 6)
    }

    private func lineAttributedString(for line: AnalysisDisplayLine) -> AttributedString {
        let tokens = lineTokens(for: line)
        var text = AttributedString()

        if line.isVariation {
            text += AttributedString("( ")
        }

        for (index, token) in tokens.enumerated() {
            let isSelectedMove = token.nodeID == state.currentAnalysisNodeID

            var movePart = AttributedString(token.moveCore)
            movePart.foregroundColor = Theme.textPrimary
            if isSelectedMove {
                movePart.backgroundColor = Theme.accent.opacity(0.28)
            }
            text += movePart

            if !token.nags.isEmpty {
                var nagsPart = AttributedString(" \(token.nags)")
                nagsPart.foregroundColor = Theme.accent
                text += nagsPart
            }

            if !token.annotation.isEmpty {
                var commentPart = AttributedString(" \(token.annotation)")
                commentPart.foregroundColor = Color(red: 0.20, green: 0.42, blue: 0.21)
                text += commentPart
            }

            if index + 1 < tokens.count {
                text += AttributedString(" ")
            }
        }

        if line.isVariation {
            text += AttributedString(" )")
        }

        return text
    }

    private func lineTokens(for line: AnalysisDisplayLine) -> [LineToken] {
        line.nodeIDs.compactMap { nodeID in
            guard let node = state.analysisNodesByID[nodeID] else { return nil }

            let ply = plyForNode(nodeID) ?? 1
            let moveCore = "\(movePrefixForPly(ply))\(node.san ?? node.uci ?? "...")"
            let nags = node.nags.joined(separator: " ")
            let annotation = node.comment.trimmingCharacters(in: .whitespacesAndNewlines)

            return LineToken(
                nodeID: nodeID,
                moveCore: moveCore,
                nags: nags,
                annotation: annotation
            )
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

    private var analysisDisplayLines: [AnalysisDisplayLine] {
        let mainlineIDs = Array(state.analysisNodeIDByPly.dropFirst())
        guard !mainlineIDs.isEmpty else { return [] }

        var lines: [AnalysisDisplayLine] = []
        var mainlineSegment: [UUID] = []

        for nodeID in mainlineIDs {
            mainlineSegment.append(nodeID)

            let branchStarts = branchStartsForMainlineNode(nodeID)
            guard !branchStarts.isEmpty else { continue }

            let segmentNodeIDs = mainlineSegment
            lines.append(
                AnalysisDisplayLine(
                    id: segmentNodeIDs.first ?? nodeID,
                    rootNodeID: nodeID,
                    nodeIDs: segmentNodeIDs,
                    depth: 0,
                    isVariation: false,
                    hasNestedVariations: true
                )
            )

            if !collapsedAnalysisNodeIDs.contains(nodeID) {
                for startID in branchStarts {
                    appendVariationLines(startNodeID: startID, depth: 1, lines: &lines)
                }
            }

            mainlineSegment.removeAll()
        }

        if !mainlineSegment.isEmpty, let lastNodeID = mainlineSegment.last {
            lines.append(
                AnalysisDisplayLine(
                    id: mainlineSegment.first ?? lastNodeID,
                    rootNodeID: lastNodeID,
                    nodeIDs: mainlineSegment,
                    depth: 0,
                    isVariation: false,
                    hasNestedVariations: false
                )
            )
        }

        return lines
    }

    private func appendVariationLines(
        startNodeID: UUID,
        depth: Int,
        lines: inout [AnalysisDisplayLine]
    ) {
        let principalIDs = principalVariationNodeIDs(from: startNodeID)
        guard !principalIDs.isEmpty else { return }

        var segment: [UUID] = []
        for nodeID in principalIDs {
            segment.append(nodeID)

            let nestedStarts = branchStartsForVariationNode(nodeID)
            guard !nestedStarts.isEmpty else { continue }

            let segmentNodeIDs = segment
            lines.append(
                AnalysisDisplayLine(
                    id: segmentNodeIDs.first ?? nodeID,
                    rootNodeID: nodeID,
                    nodeIDs: segmentNodeIDs,
                    depth: depth,
                    isVariation: true,
                    hasNestedVariations: true
                )
            )

            if !collapsedAnalysisNodeIDs.contains(nodeID) {
                for nestedStartID in nestedStarts {
                    appendVariationLines(startNodeID: nestedStartID, depth: depth + 1, lines: &lines)
                }
            }

            segment.removeAll()
        }

        if !segment.isEmpty, let lastNodeID = segment.last {
            lines.append(
                AnalysisDisplayLine(
                    id: segment.first ?? lastNodeID,
                    rootNodeID: lastNodeID,
                    nodeIDs: segment,
                    depth: depth,
                    isVariation: true,
                    hasNestedVariations: false
                )
            )
        }
    }

    private func principalVariationNodeIDs(from startNodeID: UUID) -> [UUID] {
        var nodeIDs: [UUID] = []
        var visited = Set<UUID>()
        var cursor: UUID? = startNodeID

        while let nodeID = cursor, !visited.contains(nodeID) {
            visited.insert(nodeID)
            nodeIDs.append(nodeID)
            cursor = state.analysisNodesByID[nodeID]?.children.first
        }

        return nodeIDs
    }

    private func branchStartsForMainlineNode(_ nodeID: UUID) -> [UUID] {
        guard let node = state.analysisNodesByID[nodeID] else {
            return []
        }

        if let mainlinePly = state.analysisNodeIDByPly.firstIndex(of: nodeID) {
            let nextPly = mainlinePly + 1
            if state.analysisNodeIDByPly.indices.contains(nextPly) {
                let mainlineContinuationID = state.analysisNodeIDByPly[nextPly]
                return node.children.filter { $0 != mainlineContinuationID }
            }
        }

        return node.children
    }

    private func branchStartsForVariationNode(_ nodeID: UUID) -> [UUID] {
        guard let node = state.analysisNodesByID[nodeID] else { return [] }
        return Array(node.children.dropFirst())
    }

    private func movePrefixForPly(_ ply: Int) -> String {
        let moveNumber = (ply + 1) / 2
        if ply.isMultiple(of: 2) {
            return "\(moveNumber)..."
        }
        return "\(moveNumber)."
    }

    private func toggleCollapsed(id: UUID) {
        if collapsedAnalysisNodeIDs.contains(id) {
            collapsedAnalysisNodeIDs.remove(id)
        } else {
            collapsedAnalysisNodeIDs.insert(id)
        }
    }

    private func collapseAllVariations() {
        let mainlineIDs = Array(state.analysisNodeIDByPly.dropFirst())
        var collapsed = Set<UUID>()

        for mainlineID in mainlineIDs where !branchStartsForMainlineNode(mainlineID).isEmpty {
            collapsed.insert(mainlineID)
        }

        let mainlineSet = Set(mainlineIDs)
        for node in state.analysisNodesByID.values where !mainlineSet.contains(node.id) && !branchStartsForVariationNode(node.id).isEmpty {
            collapsed.insert(node.id)
        }

        collapsedAnalysisNodeIDs = collapsed
        expandSelectedAnalysisPath()
    }

    private func expandSelectedAnalysisPath() {
        guard let selectedID = state.currentAnalysisNodeID else { return }
        var cursor: UUID? = selectedID
        while let nodeID = cursor {
            collapsedAnalysisNodeIDs.remove(nodeID)
            cursor = state.analysisNodesByID[nodeID]?.parentID
        }
    }

    private func plyForNode(_ nodeID: UUID) -> Int? {
        if let mainlinePly = state.analysisNodeIDByPly.firstIndex(of: nodeID) {
            return mainlinePly
        }

        guard state.analysisNodesByID[nodeID] != nil else { return nil }

        var visited = Set<UUID>()
        var cursor: UUID? = nodeID
        var ply = 0

        while let currentID = cursor, !visited.contains(currentID) {
            visited.insert(currentID)
            guard let node = state.analysisNodesByID[currentID] else {
                return nil
            }

            guard let parentID = node.parentID else {
                return ply
            }

            ply += 1
            cursor = parentID
        }

        return nil
    }

    private func selectAnalysisNodeFromMoveList(_ nodeID: UUID) {
        if let mainlinePly = state.analysisNodeIDByPly.firstIndex(of: nodeID) {
            state.setReplayPly(mainlinePly)
        } else {
            state.selectAnalysisNode(id: nodeID)
        }
    }

    private func annotateMove(_ nodeID: UUID) {
        selectAnalysisNodeFromMoveList(nodeID)
        editingAnnotationNodeID = nodeID
        DispatchQueue.main.async {
            inlineAnnotationFocusID = nodeID
        }
    }

    private func canDeleteMove(_ nodeID: UUID) -> Bool {
        guard state.analysisNodesByID[nodeID] != nil else { return false }
        guard nodeID != state.analysisRootNodeID else { return false }
        return !state.analysisNodeIDByPly.contains(nodeID)
    }

    private func annotationCommentBinding(for nodeID: UUID) -> Binding<String> {
        Binding(
            get: { state.analysisNodesByID[nodeID]?.comment ?? "" },
            set: { state.updateAnalysisComment(id: nodeID, comment: $0) }
        )
    }

    private func applyAnnotationSymbol(_ symbol: String, to nodeID: UUID) {
        selectAnalysisNodeFromMoveList(nodeID)
        state.applyAnalysisAnnotationSymbol(id: nodeID, symbol: symbol)
        editingAnnotationNodeID = nodeID
    }

    private func closeInlineAnnotationEditor() {
        editingAnnotationNodeID = nil
        inlineAnnotationFocusID = nil
    }

    private func isAnnotationSymbolSelected(_ symbol: String, on nodeID: UUID) -> Bool {
        state.analysisNodesByID[nodeID]?.nags.contains(symbol) == true
    }

    private func activeMoveAnnotationBadge() -> (symbol: String, color: Color)? {
        guard let currentNode = state.currentAnalysisNode else { return nil }
        let priority = ["!!", "!?", "??", "?!", "?", "!"]

        for symbol in priority where currentNode.nags.contains(symbol) {
            return (symbol, colorForAnnotationSymbol(symbol))
        }

        return nil
    }

    private func colorForAnnotationSymbol(_ symbol: String) -> Color {
        switch symbol {
        case "!!":
            return Color(red: 0.15, green: 0.47, blue: 0.94) // blue
        case "!?":
            return Color(red: 0.07, green: 0.19, blue: 0.45) // dark blue
        case "?!":
            return Color(red: 0.94, green: 0.86, blue: 0.46) // light yellow
        case "?":
            return Color(red: 0.92, green: 0.53, blue: 0.15) // orange
        case "??":
            return Color(red: 0.82, green: 0.18, blue: 0.14) // blunder
        default:
            return Theme.accent
        }
    }

    private var isCurrentAnalysisOnReplayMainline: Bool {
        guard let currentID = state.currentAnalysisNodeID else { return true }
        guard state.analysisNodeIDByPly.indices.contains(state.currentPly) else { return false }
        return state.analysisNodeIDByPly[state.currentPly] == currentID
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
        guard let squares = moveSquaresFromActiveNode() else { return [] }
        return [squares.from, squares.to]
    }

    private func lastMoveSquares() -> (from: String, to: String)? {
        moveSquaresFromActiveNode()
    }

    private func moveSquaresFromActiveNode() -> (from: String, to: String)? {
        if let uci = state.currentAnalysisNode?.uci,
           let parsed = parseUciSquares(uci) {
            return parsed
        }

        guard state.currentPly > 0 else { return nil }
        let index = state.currentPly - 1
        guard state.replayUcis.indices.contains(index) else { return nil }
        return parseUciSquares(state.replayUcis[index])
    }

    private func refreshLegalMoveLookup(for fen: String) async {
        legalMoveLookupBySource = [:]

        do {
            let legalMoves = try await state.legalMoves(fen: fen)
            if Task.isCancelled { return }
            legalMoveLookupBySource = buildLegalMoveLookup(legalMoves)
        } catch {
            if Task.isCancelled { return }
            legalMoveLookupBySource = [:]
        }
    }

    private func buildLegalMoveLookup(_ legalMoves: [String]) -> [String: [String: String]] {
        var lookup: [String: [String: String]] = [:]

        for uci in legalMoves {
            guard let squares = parseUciSquares(uci) else { continue }
            var destinations = lookup[squares.from] ?? [:]

            if let existing = destinations[squares.to] {
                if shouldPreferPromotion(from: uci, over: existing) {
                    destinations[squares.to] = uci
                }
            } else {
                destinations[squares.to] = uci
            }

            lookup[squares.from] = destinations
        }

        return lookup
    }

    private func shouldPreferPromotion(from candidate: String, over existing: String) -> Bool {
        let existingPromotion = promotionPiece(in: existing)
        let candidatePromotion = promotionPiece(in: candidate)

        if existingPromotion == "q" {
            return false
        }
        if candidatePromotion == "q" {
            return true
        }
        return false
    }

    private func promotionPiece(in uci: String) -> Character? {
        guard uci.count == 5 else { return nil }
        return Array(uci)[4]
    }

    private func parseUciSquares(_ uci: String) -> (from: String, to: String)? {
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
