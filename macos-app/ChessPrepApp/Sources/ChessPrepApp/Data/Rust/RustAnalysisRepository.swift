import Foundation

struct RustAnalysisRepository: AnalysisRepository {
    func applyMove(fen: String, uci: String) async throws -> AnalysisAppliedMove {
        let normalizedFen = fen.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUci = uci.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedFen.isEmpty else {
            throw RepositoryError.invalidInput("FEN is required.")
        }
        guard !normalizedUci.isEmpty else {
            throw RepositoryError.invalidInput("UCI move is required.")
        }

        return try await Task.detached(priority: .userInitiated) {
            try applyMoveSync(fen: normalizedFen, uci: normalizedUci)
        }
        .value
    }

    func legalMoves(fen: String) async throws -> [String] {
        let normalizedFen = fen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedFen.isEmpty else {
            throw RepositoryError.invalidInput("FEN is required.")
        }

        return try await Task.detached(priority: .userInitiated) {
            try legalMovesSync(fen: normalizedFen)
        }
        .value
    }

    func saveWorkspace(
        sourceDatabasePath: String,
        gameID: Int64,
        name: String,
        rootNodeID: UUID,
        currentNodeID: UUID?,
        nodes: [AnalysisWorkspaceNodeRecord]
    ) async throws -> Int64 {
        let normalizedSourcePath = RustBridge.expandTilde(sourceDatabasePath).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedSourcePath.isEmpty else {
            throw RepositoryError.invalidInput("Source database path is required.")
        }
        guard !normalizedName.isEmpty else {
            throw RepositoryError.invalidInput("Workspace name is required.")
        }
        guard !nodes.isEmpty else {
            throw RepositoryError.invalidInput("At least one analysis node is required.")
        }

        return try await Task.detached(priority: .userInitiated) {
            try saveWorkspaceSync(
                sourceDatabasePath: normalizedSourcePath,
                gameID: gameID,
                name: normalizedName,
                rootNodeID: rootNodeID,
                currentNodeID: currentNodeID,
                nodes: nodes
            )
        }
        .value
    }

    func listWorkspaces(sourceDatabasePath: String, gameID: Int64) async throws -> [AnalysisWorkspaceSummary] {
        let normalizedSourcePath = RustBridge.expandTilde(sourceDatabasePath).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSourcePath.isEmpty else {
            throw RepositoryError.invalidInput("Source database path is required.")
        }

        return try await Task.detached(priority: .userInitiated) {
            try listWorkspacesSync(sourceDatabasePath: normalizedSourcePath, gameID: gameID)
        }
        .value
    }

    func renameWorkspace(workspaceID: Int64, name: String) async throws {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw RepositoryError.invalidInput("Workspace name is required.")
        }

        try await Task.detached(priority: .userInitiated) {
            try renameWorkspaceSync(workspaceID: workspaceID, name: normalizedName)
        }
        .value
    }

    func deleteWorkspace(workspaceID: Int64) async throws {
        try await Task.detached(priority: .userInitiated) {
            try deleteWorkspaceSync(workspaceID: workspaceID)
        }
        .value
    }

    func loadWorkspace(workspaceID: Int64) async throws -> LoadedAnalysisWorkspace {
        return try await Task.detached(priority: .userInitiated) {
            try loadWorkspaceSync(workspaceID: workspaceID)
        }
        .value
    }

    private func applyMoveSync(fen: String, uci: String) throws -> AnalysisAppliedMove {
        let repoRoot = try RustBridge.repoRootURL()
        let binaryURL = try RustBridge.ensureBinary(repoRoot: repoRoot)
        let args = ["apply-uci", fen, uci]
        let output = try runRustCommand(repoRoot: repoRoot, binaryURL: binaryURL, arguments: args)
        return try parseAppliedMove(output)
    }

    private func legalMovesSync(fen: String) throws -> [String] {
        let repoRoot = try RustBridge.repoRootURL()
        let binaryURL = try RustBridge.ensureBinary(repoRoot: repoRoot)
        let args = ["legal-uci", fen]
        let output = try runRustCommand(repoRoot: repoRoot, binaryURL: binaryURL, arguments: args)
        return parseLegalMoves(output)
    }

    private func saveWorkspaceSync(
        sourceDatabasePath: String,
        gameID: Int64,
        name: String,
        rootNodeID: UUID,
        currentNodeID: UUID?,
        nodes: [AnalysisWorkspaceNodeRecord]
    ) throws -> Int64 {
        let repoRoot = try RustBridge.repoRootURL()
        let binaryURL = try RustBridge.ensureBinary(repoRoot: repoRoot)
        let analysisDBPath = try ensureAnalysisWorkspaceDatabase(repoRoot: repoRoot, binaryURL: binaryURL)

        let tempTSVURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("analysis-workspace-\(UUID().uuidString).tsv")
        defer {
            try? FileManager.default.removeItem(at: tempTSVURL)
        }

        try writeNodesTSV(nodes: nodes, to: tempTSVURL)

        let args: [String] = [
            "analysis-save",
            analysisDBPath,
            sourceDatabasePath,
            String(gameID),
            name,
            rootNodeID.uuidString.lowercased(),
            currentNodeID?.uuidString.lowercased() ?? "-",
            tempTSVURL.path,
        ]

        let output = try runRustCommand(repoRoot: repoRoot, binaryURL: binaryURL, arguments: args)
        guard let rowIDText = lastNonEmptyLine(in: output),
              let rowID = Int64(rowIDText) else {
            throw RepositoryError.failure("Unexpected analysis-save output.")
        }
        return rowID
    }

    private func listWorkspacesSync(
        sourceDatabasePath: String,
        gameID: Int64
    ) throws -> [AnalysisWorkspaceSummary] {
        let repoRoot = try RustBridge.repoRootURL()
        let binaryURL = try RustBridge.ensureBinary(repoRoot: repoRoot)
        let analysisDBPath = try ensureAnalysisWorkspaceDatabase(repoRoot: repoRoot, binaryURL: binaryURL)

        let args: [String] = [
            "analysis-list",
            analysisDBPath,
            sourceDatabasePath,
            String(gameID),
        ]
        let output = try runRustCommand(repoRoot: repoRoot, binaryURL: binaryURL, arguments: args)

        let rows = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return try rows.map { row in
            let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count >= 1, columns[0] == "workspace" else {
                throw RepositoryError.failure("Unexpected analysis-list row: \(row)")
            }
            return try parseWorkspaceSummary(columns: columns, rawRow: row)
        }
    }

    private func renameWorkspaceSync(workspaceID: Int64, name: String) throws {
        let repoRoot = try RustBridge.repoRootURL()
        let binaryURL = try RustBridge.ensureBinary(repoRoot: repoRoot)
        let analysisDBPath = try ensureAnalysisWorkspaceDatabase(repoRoot: repoRoot, binaryURL: binaryURL)

        let args: [String] = [
            "analysis-rename",
            analysisDBPath,
            String(workspaceID),
            name,
        ]
        _ = try runRustCommand(repoRoot: repoRoot, binaryURL: binaryURL, arguments: args)
    }

    private func deleteWorkspaceSync(workspaceID: Int64) throws {
        let repoRoot = try RustBridge.repoRootURL()
        let binaryURL = try RustBridge.ensureBinary(repoRoot: repoRoot)
        let analysisDBPath = try ensureAnalysisWorkspaceDatabase(repoRoot: repoRoot, binaryURL: binaryURL)

        let args: [String] = [
            "analysis-delete",
            analysisDBPath,
            String(workspaceID),
        ]
        _ = try runRustCommand(repoRoot: repoRoot, binaryURL: binaryURL, arguments: args)
    }

    private func loadWorkspaceSync(workspaceID: Int64) throws -> LoadedAnalysisWorkspace {
        let repoRoot = try RustBridge.repoRootURL()
        let binaryURL = try RustBridge.ensureBinary(repoRoot: repoRoot)
        let analysisDBPath = try ensureAnalysisWorkspaceDatabase(repoRoot: repoRoot, binaryURL: binaryURL)

        let args: [String] = [
            "analysis-load",
            analysisDBPath,
            String(workspaceID),
        ]
        let output = try runRustCommand(repoRoot: repoRoot, binaryURL: binaryURL, arguments: args)
        let rows = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var workspaceSummary: AnalysisWorkspaceSummary?
        var nodes: [AnalysisWorkspaceNodeRecord] = []

        for row in rows {
            let columns = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard let rowType = columns.first else { continue }

            if rowType == "workspace" {
                workspaceSummary = try parseWorkspaceSummary(columns: columns, rawRow: row)
            } else if rowType == "node" {
                nodes.append(try parseWorkspaceNode(columns: columns, rawRow: row))
            } else {
                throw RepositoryError.failure("Unexpected analysis-load row: \(row)")
            }
        }

        guard let workspaceSummary else {
            throw RepositoryError.failure("Analysis workspace payload missing summary row.")
        }

        return LoadedAnalysisWorkspace(workspace: workspaceSummary, nodes: nodes)
    }

    private func parseWorkspaceSummary(
        columns: [Substring],
        rawRow: String
    ) throws -> AnalysisWorkspaceSummary {
        guard columns.count == 9 else {
            throw RepositoryError.failure("Unexpected workspace row format: \(rawRow)")
        }
        guard let id = Int64(columns[1]) else {
            throw RepositoryError.failure("Invalid workspace id in row: \(rawRow)")
        }
        guard let gameID = Int64(columns[3]) else {
            throw RepositoryError.failure("Invalid workspace game id in row: \(rawRow)")
        }
        guard let createdAt = Int64(columns[7]),
              let updatedAt = Int64(columns[8]) else {
            throw RepositoryError.failure("Invalid workspace timestamps in row: \(rawRow)")
        }
        guard let rootNodeID = UUID(uuidString: String(columns[5])) else {
            throw RepositoryError.failure("Invalid workspace root node id in row: \(rawRow)")
        }

        let currentNodeID: UUID?
        if columns[6].isEmpty {
            currentNodeID = nil
        } else {
            guard let value = UUID(uuidString: String(columns[6])) else {
                throw RepositoryError.failure("Invalid workspace current node id in row: \(rawRow)")
            }
            currentNodeID = value
        }

        return AnalysisWorkspaceSummary(
            id: id,
            sourceDatabasePath: String(columns[2]),
            gameID: gameID,
            name: String(columns[4]),
            rootNodeID: rootNodeID,
            currentNodeID: currentNodeID,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
        )
    }

    private func parseWorkspaceNode(
        columns: [Substring],
        rawRow: String
    ) throws -> AnalysisWorkspaceNodeRecord {
        guard columns.count == 9 else {
            throw RepositoryError.failure("Unexpected node row format: \(rawRow)")
        }
        guard let nodeID = UUID(uuidString: String(columns[1])) else {
            throw RepositoryError.failure("Invalid node id in row: \(rawRow)")
        }

        let parentID: UUID?
        if columns[2].isEmpty {
            parentID = nil
        } else {
            guard let value = UUID(uuidString: String(columns[2])) else {
                throw RepositoryError.failure("Invalid node parent id in row: \(rawRow)")
            }
            parentID = value
        }

        guard let sortIndex = Int(columns[8]) else {
            throw RepositoryError.failure("Invalid node sort index in row: \(rawRow)")
        }

        let san = columns[3].isEmpty ? nil : String(columns[3])
        let uci = columns[4].isEmpty ? nil : String(columns[4])
        let nags = parseNags(String(columns[7]))

        return AnalysisWorkspaceNodeRecord(
            id: nodeID,
            parentID: parentID,
            san: san,
            uci: uci,
            fen: String(columns[5]),
            comment: String(columns[6]),
            nags: nags,
            sortIndex: sortIndex
        )
    }

    private func ensureAnalysisWorkspaceDatabase(
        repoRoot: URL,
        binaryURL: URL
    ) throws -> String {
        let dbPath = try analysisWorkspaceDBPath()
        _ = try runRustCommand(
            repoRoot: repoRoot,
            binaryURL: binaryURL,
            arguments: ["analysis-init", dbPath]
        )
        return dbPath
    }

    private func analysisWorkspaceDBPath() throws -> String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChessPrepApp", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("analysis-workspaces.sqlite").path
    }

    private func runRustCommand(
        repoRoot: URL,
        binaryURL: URL,
        arguments: [String]
    ) throws -> String {
        do {
            return try RustBridge.runProcess(
                executableURL: binaryURL,
                arguments: arguments,
                workingDirectory: repoRoot
            )
        } catch {
            guard RustBridge.canBuildBinary(repoRoot: repoRoot) else {
                throw error
            }
            try RustBridge.buildBinary(repoRoot: repoRoot)
            return try RustBridge.runProcess(
                executableURL: binaryURL,
                arguments: arguments,
                workingDirectory: repoRoot
            )
        }
    }

    private func writeNodesTSV(
        nodes: [AnalysisWorkspaceNodeRecord],
        to url: URL
    ) throws {
        let lines = nodes.map { node in
            let parent = node.parentID?.uuidString.lowercased() ?? ""
            let san = node.san ?? ""
            let uci = node.uci ?? ""
            let nags = node.nags.joined(separator: ",")

            return [
                node.id.uuidString.lowercased(),
                parent,
                san,
                uci,
                node.fen,
                node.comment,
                nags,
                String(node.sortIndex),
            ]
            .map(tsvSanitized)
            .joined(separator: "\t")
        }

        let body = lines.joined(separator: "\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    private func tsvSanitized(_ value: String) -> String {
        value.replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private func parseAppliedMove(_ output: String) throws -> AnalysisAppliedMove {
        let line = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })

        guard let line else {
            throw RepositoryError.failure("Analysis move command returned no output.")
        }

        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count == 3 else {
            throw RepositoryError.failure("Unexpected analysis move output format: \(line)")
        }

        return AnalysisAppliedMove(
            san: String(columns[0]),
            uci: String(columns[1]),
            fen: String(columns[2])
        )
    }

    private func parseLegalMoves(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func parseNags(_ raw: String) -> [String] {
        raw.split(separator: ",")
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func lastNonEmptyLine(in output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
    }
}
