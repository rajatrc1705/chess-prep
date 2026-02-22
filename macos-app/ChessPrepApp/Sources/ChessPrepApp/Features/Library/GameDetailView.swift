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
    @State private var legalMovesCacheByFen: [String: [String]] = [:]
    @State private var availableEnginePaths: [String] = []
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
    private let quickAnnotationSymbols: [String] = ["!", "?", "!!", "??", "!?", "?!"]

    private struct AnalysisDisplayLine: Identifiable {
        let id: UUID
        let rootNodeID: UUID
        let nodeIDs: [UUID]
        let depth: Int
        let isVariation: Bool
        let hasNestedVariations: Bool
    }

    private struct LineToken: Identifiable {
        var id: UUID { nodeID }
        let nodeID: UUID
        let moveCore: String
        let nags: String
        let annotation: String
    }

    private struct PathGraphBarEntry: Identifiable {
        let nodeID: UUID
        let ply: Int
        let x: CGFloat
        let height: CGFloat
        let width: CGFloat
        let isPositive: Bool
        let isEvaluated: Bool
        let scoreLabel: String

        var id: UUID { nodeID }
    }

    private struct MoveTokenFlowLayout: Layout {
        let itemSpacing: CGFloat
        let lineSpacing: CGFloat

        init(itemSpacing: CGFloat = 6, lineSpacing: CGFloat = 6) {
            self.itemSpacing = itemSpacing
            self.lineSpacing = lineSpacing
        }

        func sizeThatFits(
            proposal: ProposedViewSize,
            subviews: Subviews,
            cache: inout ()
        ) -> CGSize {
            let maxWidth = proposal.width ?? .greatestFiniteMagnitude
            guard !subviews.isEmpty else { return .zero }

            var x: CGFloat = 0
            var y: CGFloat = 0
            var rowHeight: CGFloat = 0
            var usedWidth: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x > 0, x + size.width > maxWidth {
                    y += rowHeight + lineSpacing
                    x = 0
                    rowHeight = 0
                }

                usedWidth = max(usedWidth, x + size.width)
                x += size.width + itemSpacing
                rowHeight = max(rowHeight, size.height)
            }

            return CGSize(
                width: proposal.width ?? usedWidth,
                height: y + rowHeight
            )
        }

        func placeSubviews(
            in bounds: CGRect,
            proposal: ProposedViewSize,
            subviews: Subviews,
            cache: inout ()
        ) {
            let maxWidth = bounds.width
            var x = bounds.minX
            var y = bounds.minY
            var rowHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if x > bounds.minX, x + size.width > bounds.minX + maxWidth {
                    y += rowHeight + lineSpacing
                    x = bounds.minX
                    rowHeight = 0
                }

                subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )

                x += size.width + itemSpacing
                rowHeight = max(rowHeight, size.height)
            }
        }
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
            refreshEngineOptions()
            state.scheduleAnalysisPathGraphEvaluation()
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
            legalMovesCacheByFen = [:]
            editingAnnotationNodeID = nil
            inlineAnnotationFocusID = nil
            state.scheduleAnalysisPathGraphEvaluation()
        }
        .onChange(of: state.currentAnalysisNodeID) { _, _ in
            expandSelectedAnalysisPath()
            state.scheduleAnalysisPathGraphEvaluation()
        }
        .onChange(of: state.analysisNodesByID.count) { _, _ in
            state.scheduleAnalysisPathGraphEvaluation()
        }
        .onChange(of: inlineAnnotationFocusID) { _, nextFocus in
            if nextFocus == nil {
                editingAnnotationNodeID = nil
            }
        }
        .onChange(of: state.enginePath) { _, _ in
            refreshEngineOptions()
            state.scheduleAnalysisPathGraphEvaluation()
        }
        .onChange(of: state.engineDepth) { _, _ in
            state.scheduleAnalysisPathGraphEvaluation()
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
                pathEbbFlowPanel
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.surfaceAlt.opacity(0.55))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Theme.border.opacity(0.25), lineWidth: 1)
                    )

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
                .onAppear {
                    state.scheduleAutoAnalyze(for: boardFen)
                }
                .onChange(of: boardFen) { _, nextFen in
                    state.scheduleAutoAnalyze(for: nextFen)
                }
                .onChange(of: state.enginePath) { _, _ in
                    state.scheduleAutoAnalyze(for: boardFen)
                }
                .onChange(of: state.engineDepth) { _, _ in
                    state.scheduleAutoAnalyze(for: boardFen)
                }
                .onChange(of: state.engineTopLineCount) { _, _ in
                    state.scheduleAutoAnalyze(for: boardFen)
                }
                .onChange(of: state.autoAnalyzeEngine) { _, enabled in
                    if enabled {
                        state.scheduleAutoAnalyze(for: boardFen)
                    }
                }

                replayControlAndEnginePanel(currentFen: boardFen)
            } else {
                Text("No replay data available for this game yet.")
                    .font(Typography.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func replayControlAndEnginePanel(currentFen: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
                statusChip(title: "Node", value: state.currentAnalysisNode?.san ?? "Start")
            }

            if let analysisError = state.analysisError {
                Text(analysisError)
                    .font(Typography.body)
                    .foregroundStyle(Theme.error)
            }

            if !isCurrentAnalysisOnReplayMainline {
                Text("Viewing analysis variation from replay ply \(state.currentPly).")
                    .font(Typography.detailLabel)
                    .foregroundStyle(Theme.textSecondary)
            }

            analysisWorkspacePanel()

            Divider()
                .padding(.top, 2)

            enginePanel(currentFen: currentFen)
        }
        .padding(12)
        .background(Theme.surfaceAlt.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Theme.border.opacity(0.25), lineWidth: 1)
        )
    }

    private func analysisWorkspacePanel() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Analysis Workspace")
                .font(Typography.detailLabel)

            HStack(spacing: 8) {
                TextField("Workspace name", text: $state.analysisWorkspaceName)
                    .textFieldStyle(.roundedBorder)

                Button {
                    Task {
                        await state.saveCurrentAnalysisWorkspace()
                    }
                } label: {
                    if state.isSavingAnalysisWorkspace {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Saving...")
                        }
                    } else {
                        Text("Save")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(state.isSavingAnalysisWorkspace || state.analysisNodesByID.isEmpty)
            }

            HStack(spacing: 8) {
                Picker("Saved Analysis", selection: $state.selectedAnalysisWorkspaceID) {
                    Text("No saved analysis").tag(Optional<Int64>.none)
                    ForEach(state.analysisWorkspaceSummaries) { workspace in
                        Text(analysisWorkspaceLabel(workspace))
                            .tag(Optional(workspace.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    Task {
                        await state.refreshAnalysisWorkspaces()
                    }
                } label: {
                    if state.isLoadingAnalysisWorkspaceList {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Refresh")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(state.isLoadingAnalysisWorkspaceList)

                Button {
                    Task {
                        await state.loadSelectedAnalysisWorkspace()
                    }
                } label: {
                    if state.isLoadingAnalysisWorkspace {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Loading...")
                        }
                    } else {
                        Text("Load")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(state.selectedAnalysisWorkspaceID == nil || state.isLoadingAnalysisWorkspace)

                Button {
                    Task {
                        await state.renameSelectedAnalysisWorkspace()
                    }
                } label: {
                    if state.isRenamingAnalysisWorkspace {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Rename")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(
                    state.selectedAnalysisWorkspaceID == nil
                        || state.isRenamingAnalysisWorkspace
                        || state.analysisWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )

                Button(role: .destructive) {
                    Task {
                        await state.deleteSelectedAnalysisWorkspace()
                    }
                } label: {
                    if state.isDeletingAnalysisWorkspace {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Delete")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(state.selectedAnalysisWorkspaceID == nil || state.isDeletingAnalysisWorkspace)
            }

            HStack(spacing: 8) {
                if let loadedName = state.loadedAnalysisWorkspaceName,
                   !loadedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    statusChip(title: "Loaded", value: loadedName)
                }
                if let savedName = state.lastSavedAnalysisWorkspaceName,
                   !savedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    statusChip(title: "Last Saved", value: savedName)
                }
                if state.analysisWorkspaceIsDirty {
                    statusChip(title: "State", value: "Unsaved changes")
                }
            }

            if let status = state.analysisWorkspaceStatus,
               !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(status)
                    .font(Typography.detailLabel)
                    .foregroundStyle(Theme.textSecondary)
            }

            if let error = state.analysisWorkspaceError,
               !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(error)
                    .font(Typography.detailLabel)
                    .foregroundStyle(Theme.error)
            }
        }
        .padding(.vertical, 4)
    }

    private func analysisWorkspaceLabel(_ workspace: AnalysisWorkspaceSummary) -> String {
        let updated = Self.workspaceDateFormatter.string(from: workspace.updatedAt)
        return "\(workspace.name) (\(updated))"
    }

    private static let workspaceDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()

    private func enginePanel(currentFen: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Engine Analysis")
                .font(Typography.detailLabel)

            HStack(spacing: 8) {
                Label("Engine", systemImage: "cpu")
                    .font(Typography.detailLabel)
                    .foregroundStyle(Theme.textSecondary)

                Picker("Engine", selection: $state.enginePath) {
                    if availableEnginePaths.isEmpty {
                        Text("No engines detected").tag("")
                    } else {
                        ForEach(availableEnginePaths, id: \.self) { path in
                            Text(engineOptionLabel(for: path)).tag(path)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 320, alignment: .leading)
                .disabled(availableEnginePaths.isEmpty)

                Button {
                    chooseEngineBinary()
                } label: {
                    Label("Browse", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Spacer()
            }

            Toggle("Auto Analyze Current Position", isOn: $state.autoAnalyzeEngine)
                .toggleStyle(.switch)
                .font(Typography.detailLabel)

            if let engineError = state.engineError {
                Text(engineError)
                    .font(Typography.body)
                    .foregroundStyle(Theme.error)
            }
        }
        .padding(.top, 6)
    }

    private func refreshEngineOptions() {
        let detected = detectedEnginePaths()
        let current = state.enginePath.trimmingCharacters(in: .whitespacesAndNewlines)

        var merged: [String] = []
        if !current.isEmpty {
            merged.append(current)
        }
        merged.append(contentsOf: detected)

        var seen = Set<String>()
        var unique: [String] = []
        for path in merged {
            if seen.insert(path).inserted {
                unique.append(path)
            }
        }

        availableEnginePaths = unique

        if current.isEmpty, let first = availableEnginePaths.first {
            state.enginePath = first
        }
    }

    private func detectedEnginePaths() -> [String] {
        let bundledPath = RustBridge.bundledEnginePath()
        let commonPaths = [
            bundledPath,
            "/opt/homebrew/bin/stockfish",
            "/opt/homebrew/opt/stockfish/bin/stockfish",
            "/usr/local/bin/stockfish",
            "/usr/bin/stockfish",
            "/Applications/Stockfish.app/Contents/MacOS/Stockfish",
        ].compactMap { $0 }

        let engineNames = ["stockfish", "lc0"]
        let pathEntries = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []

        var candidates = commonPaths
        for entry in pathEntries {
            for engineName in engineNames {
                candidates.append((entry as NSString).appendingPathComponent(engineName))
            }
        }

        var seen = Set<String>()
        var out: [String] = []
        for candidate in candidates {
            let expanded = (candidate as NSString).expandingTildeInPath
            guard FileManager.default.isExecutableFile(atPath: expanded) else { continue }
            if seen.insert(expanded).inserted {
                out.append(expanded)
            }
        }
        return out
    }

    private func engineOptionLabel(for path: String) -> String {
        if let bundledPath = RustBridge.bundledEnginePath(),
           RustBridge.expandTilde(path) == RustBridge.expandTilde(bundledPath) {
            return "stockfish  (Bundled)"
        }
        let url = URL(fileURLWithPath: path)
        let fileName = url.lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        guard !parent.isEmpty else { return fileName }
        return "\(fileName)  (\(parent))"
    }

    private func chooseEngineBinary() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.title = "Select UCI Engine Binary"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            state.enginePath = url.path
            refreshEngineOptions()
        }
        #endif
    }

    private var analysisMoveListView: some View {
        GeometryReader { proxy in
            let moveTreeHeight = max(180, proxy.size.height * 0.56)

            VStack(alignment: .leading, spacing: 10) {
                moveTreePanel
                    .frame(height: moveTreeHeight)

                Divider()

                moveNotationEngineLinesPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(12)
            .background(Theme.surfaceAlt.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.border.opacity(0.25), lineWidth: 1)
            )
        }
    }

    private var moveTreePanel: some View {
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

                HStack(spacing: 6) {
                    Text("Quick NAG")
                        .font(Typography.detailLabel)
                        .foregroundStyle(Theme.textSecondary)

                    ForEach(quickAnnotationSymbols, id: \.self) { symbol in
                        Button(symbol) {
                            guard let nodeID = selectedQuickAnnotationNodeID else { return }
                            applyAnnotationSymbol(symbol, to: nodeID)
                        }
                        .buttonStyle(.plain)
                        .font(Typography.dataMono)
                        .frame(width: 36, height: 24)
                        .background(
                            selectedQuickAnnotationNodeID.flatMap { nodeID in
                                isAnnotationSymbolSelected(symbol, on: nodeID) ? Theme.accent.opacity(0.22) : Theme.surface
                            } ?? Theme.surface
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(
                                    selectedQuickAnnotationNodeID.flatMap { nodeID in
                                        isAnnotationSymbolSelected(symbol, on: nodeID) ? Theme.accent : Theme.border.opacity(0.3)
                                    } ?? Theme.border.opacity(0.3),
                                    lineWidth: 1
                                )
                        )
                        .disabled(selectedQuickAnnotationNodeID == nil)
                    }
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
    }

    private var moveNotationEngineLinesPanel: some View {
        engineLinesPanel
    }

    private var pathEbbFlowPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Path Ebb/Flow")
                    .font(Typography.detailLabel)
                    .foregroundStyle(Theme.textSecondary)

                Spacer()

                if let status = pathGraphStatusLabel {
                    Text(status)
                        .font(Typography.dataMono)
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.surfaceAlt.opacity(0.35))

                if state.analysisPathGraphPoints.isEmpty {
                    Text(pathGraphEmptyMessage)
                        .font(Typography.detailLabel)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .padding(.horizontal, 8)
                } else {
                    GeometryReader { proxy in
                        let canvasWidth = pathGraphCanvasWidth(availableWidth: proxy.size.width)
                        ScrollView(.horizontal, showsIndicators: true) {
                            let canvasSize = CGSize(width: canvasWidth, height: proxy.size.height)
                            let bars = pathGraphBarEntries(in: canvasSize)
                            let centerY = canvasSize.height / 2

                            ZStack(alignment: .topLeading) {
                                Path { path in
                                    path.move(to: CGPoint(x: 8, y: centerY))
                                    path.addLine(to: CGPoint(x: max(canvasSize.width - 8, 8), y: centerY))
                                }
                                .stroke(Theme.border.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))

                                ForEach(bars) { bar in
                                    Button {
                                        selectAnalysisNodeFromMoveList(bar.nodeID)
                                    } label: {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(pathGraphBarColor(for: bar))
                                            .frame(width: bar.width, height: bar.height)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 2)
                                                    .stroke(
                                                        bar.nodeID == state.currentAnalysisNodeID
                                                            ? Theme.accent
                                                            : .clear,
                                                        lineWidth: 1.5
                                                    )
                                            )
                                    }
                                    .buttonStyle(.plain)
                                    .position(
                                        x: bar.x,
                                        y: bar.isPositive
                                            ? centerY - (bar.height / 2) - 1
                                            : centerY + (bar.height / 2) + 1
                                    )
                                    .help("Ply \(bar.ply)  \(bar.scoreLabel)")
                                }
                            }
                            .frame(width: canvasWidth, height: proxy.size.height)
                        }
                    }
                }

                if state.isLoadingAnalysisPathGraph,
                   let progress = state.analysisPathGraphProgressText {
                    Text(progress)
                        .font(Typography.detailLabel)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Theme.surface.opacity(0.92))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
            }
            .frame(height: 48)

            if state.analysisPathGraphIsTruncated {
                Text("Graph limited to first 120 plies.")
                    .font(Typography.detailLabel)
                    .foregroundStyle(Theme.textSecondary)
            }

            if let graphError = state.analysisPathGraphError,
               !graphError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(graphError)
                    .font(Typography.detailLabel)
                    .foregroundStyle(Theme.error)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var pathGraphStatusLabel: String? {
        guard let currentNodeID = state.currentAnalysisNodeID else { return nil }
        guard let point = state.analysisPathGraphPoints.first(where: { $0.nodeID == currentNodeID }) else { return nil }
        return "Ply \(point.ply)  \(point.scoreLabel)"
    }

    private var pathGraphEmptyMessage: String {
        if state.enginePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Select engine to show path bars."
        }
        if state.analysisNodesByID.isEmpty {
            return "No analysis path."
        }
        return "Evaluating path..."
    }

    private func pathGraphCanvasWidth(availableWidth: CGFloat) -> CGFloat {
        let horizontalPadding: CGFloat = 8
        let slotWidth: CGFloat = 7
        let required = horizontalPadding * 2 + CGFloat(max(state.analysisPathGraphPoints.count, 1)) * slotWidth
        return max(availableWidth, required)
    }

    private func pathGraphBarEntries(in size: CGSize) -> [PathGraphBarEntry] {
        guard !state.analysisPathGraphPoints.isEmpty else { return [] }

        let values = state.analysisPathGraphPoints.compactMap(\.plotValue)
        let absScale = max(values.map(abs).max() ?? 100, 50)
        let horizontalPadding: CGFloat = 8
        let usableWidth = max(size.width - (horizontalPadding * 2), 1)
        let count = max(state.analysisPathGraphPoints.count, 1)
        let spacing = usableWidth / CGFloat(count)
        let barWidth = min(8, max(2, spacing * 0.65))
        let maxHalfHeight = max((size.height / 2) - 6, 3)

        return state.analysisPathGraphPoints.enumerated().map { index, point in
            let value = point.plotValue ?? 0
            let normalized = min(abs(value) / absScale, 1)
            let barHeight = max(2, CGFloat(normalized) * maxHalfHeight)
            let x = horizontalPadding + (CGFloat(index) * spacing) + (spacing / 2)

            return PathGraphBarEntry(
                nodeID: point.nodeID,
                ply: point.ply,
                x: x,
                height: barHeight,
                width: barWidth,
                isPositive: value >= 0,
                isEvaluated: point.isEvaluated,
                scoreLabel: point.scoreLabel
            )
        }
    }

    private func pathGraphBarColor(for bar: PathGraphBarEntry) -> Color {
        if bar.nodeID == state.currentAnalysisNodeID {
            return Theme.accent
        }
        if !bar.isEvaluated {
            return Theme.textSecondary.opacity(0.25)
        }
        if bar.isPositive {
            return Color(red: 0.18, green: 0.60, blue: 0.29).opacity(0.9)
        }
        return Color(red: 0.80, green: 0.20, blue: 0.20).opacity(0.9)
    }

    private var engineLinesPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Engine Lines")
                    .font(Typography.detailLabel)
                    .foregroundStyle(Theme.textSecondary)

                Spacer()
            }

            HStack(spacing: 10) {
                Stepper(value: $state.engineDepth, in: 1...60) {
                    Text("Depth \(state.engineDepth)")
                        .font(Typography.dataMono)
                }

                Picker("Lines", selection: $state.engineTopLineCount) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                    Text("3").tag(3)
                }
                .pickerStyle(.segmented)
                .frame(width: 146)

                Button {
                    Task {
                        await state.analyzeCurrentPosition()
                    }
                } label: {
                    if state.isAnalyzingEngine {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(state.autoAnalyzeEngine ? "Auto Analyzing..." : "Analyzing...")
                        }
                    } else {
                        Text("Analyze Now")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(
                    state.isAnalyzingEngine
                        || state.currentFen?.isEmpty != false
                        || state.enginePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }

            if state.isAnalyzingEngine {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating engine lines...")
                        .font(Typography.detailLabel)
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if let engineError = state.engineError {
                Text(engineError)
                    .font(Typography.detailLabel)
                    .foregroundStyle(Theme.error)
            } else if let analysis = state.engineAnalysis {
                let topLines = Array(analysis.displayLines.prefix(state.engineTopLineCount))
                if topLines.isEmpty {
                    Text("No engine lines available yet.")
                        .font(Typography.detailLabel)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(topLines) { line in
                                HStack(alignment: .top, spacing: 8) {
                                    Text("#\(line.multipvRank)")
                                        .font(Typography.detailLabel)
                                        .foregroundStyle(Theme.textSecondary)
                                        .frame(width: 24, alignment: .leading)

                                    Text(line.scoreLabel)
                                        .font(Typography.dataMono)
                                        .frame(width: 54, alignment: .leading)

                                    Text(line.displayPv.joined(separator: " "))
                                        .font(Typography.dataMono)
                                        .foregroundStyle(Theme.textSecondary)
                                        .lineLimit(2)
                                        .textSelection(.enabled)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(line.multipvRank == 1 ? Theme.accent.opacity(0.14) : Theme.surfaceAlt.opacity(0.55))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                        }
                    }
                }
            } else {
                Text("Run engine analysis to populate lines here.")
                    .font(Typography.detailLabel)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func analysisDisplayLineView(_ line: AnalysisDisplayLine) -> some View {
        let isCollapsed = collapsedAnalysisNodeIDs.contains(line.rootNodeID)
        let tokens = lineTokens(for: line)

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

                MoveTokenFlowLayout(itemSpacing: 6, lineSpacing: 6) {
                    if line.isVariation {
                        Text("(")
                            .font(Typography.dataMono)
                            .foregroundStyle(Theme.textSecondary)
                    }

                    ForEach(tokens) { token in
                        moveTokenButton(token)
                    }

                    if line.isVariation {
                        Text(")")
                            .font(Typography.dataMono)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let editingNodeID = editingAnnotationNodeID,
               line.nodeIDs.contains(editingNodeID) {
                inlineAnnotationEditor(
                    nodeID: editingNodeID,
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

    private func moveTokenButton(_ token: LineToken) -> some View {
        Button {
            selectAnalysisNodeFromMoveList(token.nodeID)
        } label: {
            Text(tokenAttributedString(token))
                .font(Typography.dataMono)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                    token.nodeID == state.currentAnalysisNodeID
                        ? Theme.accent.opacity(0.28)
                        : .clear
                )
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Annotate") {
                annotateMove(token.nodeID)
            }

            Button("Delete Move", role: .destructive) {
                state.deleteAnalysisNode(id: token.nodeID)
            }
            .disabled(!canDeleteMove(token.nodeID))

            Divider()

            ForEach(annotationSymbolOptions, id: \.self) { symbol in
                Button {
                    applyAnnotationSymbol(symbol, to: token.nodeID)
                } label: {
                    if isAnnotationSymbolSelected(symbol, on: token.nodeID) {
                        Label(symbol, systemImage: "checkmark")
                    } else {
                        Text(symbol)
                    }
                }
            }
        }
    }

    private func tokenAttributedString(_ token: LineToken) -> AttributedString {
        var text = AttributedString(token.moveCore)
        text.foregroundColor = Theme.textPrimary

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

        return text
    }

    private func lineTokens(for line: AnalysisDisplayLine) -> [LineToken] {
        guard let firstNodeID = line.nodeIDs.first else { return [] }
        let basePly = plyForNode(firstNodeID) ?? 1

        return line.nodeIDs.enumerated().compactMap { index, nodeID in
            guard let node = state.analysisNodesByID[nodeID] else { return nil }

            let ply = basePly + index
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

    private var selectedQuickAnnotationNodeID: UUID? {
        guard let nodeID = state.currentAnalysisNodeID else { return nil }
        guard let node = state.analysisNodesByID[nodeID] else { return nil }
        guard nodeID != state.analysisRootNodeID else { return nil }
        guard node.san != nil || node.uci != nil else { return nil }
        return nodeID
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
        closeInlineAnnotationEditor()
        selectAnalysisNodeFromMoveList(nodeID)
        state.applyAnalysisAnnotationSymbol(id: nodeID, symbol: symbol)
    }

    private func closeInlineAnnotationEditor() {
        editingAnnotationNodeID = nil
        inlineAnnotationFocusID = nil
        DispatchQueue.main.async {
            replayFocused = true
        }
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
        if let cachedMoves = legalMovesCacheByFen[fen] {
            legalMoveLookupBySource = buildLegalMoveLookup(cachedMoves)
            return
        }

        do {
            let legalMoves = try await state.legalMoves(fen: fen)
            if Task.isCancelled { return }
            if legalMovesCacheByFen.count > 400 {
                legalMovesCacheByFen.removeAll(keepingCapacity: true)
            }
            legalMovesCacheByFen[fen] = legalMoves
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
