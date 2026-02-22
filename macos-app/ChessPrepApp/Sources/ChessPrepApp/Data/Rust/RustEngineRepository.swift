import Foundation
import Darwin

private func whitePerspectiveFactor(for fen: String) -> Int {
    let fields = fen.split(separator: " ", omittingEmptySubsequences: true)
    guard fields.count > 1 else { return 1 }
    return fields[1] == "b" ? -1 : 1
}

private func normalizeScore(_ value: Int?, factor: Int) -> Int? {
    guard let value else { return nil }
    return value * factor
}

private func normalizeEngineLine(_ line: EngineLine, factor: Int) -> EngineLine {
    EngineLine(
        multipvRank: line.multipvRank,
        depth: line.depth,
        scoreCp: normalizeScore(line.scoreCp, factor: factor),
        scoreMate: normalizeScore(line.scoreMate, factor: factor),
        pv: line.pv,
        sanPv: line.sanPv
    )
}

private func normalizeEngineAnalysis(
    _ analysis: EngineAnalysis,
    lines: [EngineLine],
    factor: Int
) -> EngineAnalysis {
    EngineAnalysis(
        depth: analysis.depth,
        scoreCp: normalizeScore(analysis.scoreCp, factor: factor),
        scoreMate: normalizeScore(analysis.scoreMate, factor: factor),
        bestMove: analysis.bestMove,
        pv: analysis.pv,
        lines: lines.map { normalizeEngineLine($0, factor: factor) }
    )
}

private enum EngineSessionTimeoutError: Error {
    case timedOut
}

private actor RustEngineSessionMode {
    private var isDisabled = false

    func persistentSessionEnabled() -> Bool {
        !isDisabled
    }

    func disablePersistentSession() {
        isDisabled = true
    }
}

private actor RustEngineSessionStore {
    private struct SessionKey: Equatable {
        let binaryPath: String
        let enginePath: String
    }

    private var sessionKey: SessionKey?
    private var session: RustEngineSession?

    func analyze(
        repoRoot: URL,
        binaryURL: URL,
        enginePath: String,
        fen: String,
        depth: Int,
        multipv: Int
    ) throws -> EngineAnalysis {
        let desiredKey = SessionKey(binaryPath: binaryURL.path, enginePath: enginePath)

        if sessionKey != desiredKey {
            session?.shutdown()
            session = try RustEngineSession(repoRoot: repoRoot, binaryURL: binaryURL, enginePath: enginePath)
            sessionKey = desiredKey
        }

        guard let session else {
            throw RepositoryError.failure("Engine session is unavailable.")
        }

        do {
            return try session.analyze(fen: fen, depth: depth, multipv: multipv)
        } catch {
            if error is EngineSessionTimeoutError || !session.isRunning {
                session.shutdown()
                self.session = nil
                self.sessionKey = nil
            }
            throw error
        }
    }
}

private final class RustEngineSession {
    private final class LineReader {
        private let fd: Int32
        private var buffer = Data()
        private let newline = Data([0x0A])

        init(handle: FileHandle) {
            self.fd = handle.fileDescriptor
        }

        private func popBufferedLine() -> String? {
            if let range = buffer.range(of: newline) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                return String(decoding: lineData, as: UTF8.self)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            }
            return nil
        }

        private func readChunk(timeoutMilliseconds: Int32) throws -> Int {
            var descriptor = pollfd(
                fd: fd,
                events: Int16(POLLIN | POLLERR | POLLHUP),
                revents: 0
            )

            while true {
                let pollResult = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
                if pollResult == 0 {
                    throw EngineSessionTimeoutError.timedOut
                }
                if pollResult > 0 {
                    break
                }
                if errno == EINTR {
                    continue
                }
                throw RepositoryError.failure("Engine I/O poll failed (\(errno)).")
            }

            var chunk = [UInt8](repeating: 0, count: 4096)
            let bytesRead = Darwin.read(fd, &chunk, chunk.count)
            if bytesRead < 0 {
                if errno == EINTR {
                    return try readChunk(timeoutMilliseconds: timeoutMilliseconds)
                }
                throw RepositoryError.failure("Engine I/O read failed (\(errno)).")
            }
            if bytesRead > 0 {
                buffer.append(contentsOf: chunk.prefix(Int(bytesRead)))
            }
            return Int(bytesRead)
        }

        func readLine(timeoutSeconds: Double) throws -> String? {
            if let line = popBufferedLine() {
                return line
            }

            let deadline = Date().addingTimeInterval(timeoutSeconds)

            while true {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 {
                    throw EngineSessionTimeoutError.timedOut
                }

                let timeoutMsInt = max(1, min(Int(remaining * 1000), Int(Int32.max)))
                let timeoutMilliseconds = Int32(timeoutMsInt)
                let bytesRead = try readChunk(timeoutMilliseconds: timeoutMilliseconds)

                if bytesRead == 0 {
                    if buffer.isEmpty {
                        return nil
                    }

                    let lineData = buffer
                    buffer.removeAll(keepingCapacity: false)
                    return String(decoding: lineData, as: UTF8.self).trimmingCharacters(
                        in: CharacterSet(charactersIn: "\r")
                    )
                }

                if let line = popBufferedLine() {
                    return line
                }
            }
        }
    }

    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutReader: LineReader
    private let stderrHandle: FileHandle

    var isRunning: Bool {
        process.isRunning
    }

    init(repoRoot: URL, binaryURL: URL, enginePath: String) throws {
        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["engine-session", enginePath]
        process.currentDirectoryURL = repoRoot

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutReader = LineReader(handle: stdoutPipe.fileHandleForReading)
        self.stderrHandle = stderrPipe.fileHandleForReading

        guard let firstLine = try stdoutReader.readLine(timeoutSeconds: 3) else {
            shutdown()
            let stderr = String(decoding: stderrHandle.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if stderr.isEmpty {
                throw RepositoryError.failure("Engine session exited before signaling readiness.")
            }
            throw RepositoryError.failure(stderr)
        }

        guard firstLine == "ready" else {
            shutdown()
            if firstLine.hasPrefix("err\t") {
                throw RepositoryError.failure(String(firstLine.dropFirst(4)))
            }
            throw RepositoryError.failure("Unexpected engine session startup output: \(firstLine)")
        }
    }

    deinit {
        shutdown()
    }

    func analyze(fen: String, depth: Int, multipv: Int) throws -> EngineAnalysis {
        let safeMultipv = max(1, min(multipv, 10))
        let perspectiveFactor = whitePerspectiveFactor(for: fen)
        try writeLine("analyze-multipv\t\(depth)\t\(safeMultipv)\t\(fen)")

        var summary: EngineAnalysis?
        var lines: [EngineLine] = []

        while let line = try stdoutReader.readLine(timeoutSeconds: 10) {
            let rawLine = line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            if rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }

            if rawLine.hasPrefix("ok-multipv\t") {
                summary = try parseMultipvSummary(rawLine)
                continue
            }

            if rawLine.hasPrefix("line\t") {
                lines.append(try parseMultipvLine(rawLine))
                continue
            }

            if rawLine == "done" {
                guard let summary else {
                    throw RepositoryError.failure("Engine returned malformed MultiPV output.")
                }
                let normalizedSummary = normalizeEngineAnalysis(summary, lines: [], factor: perspectiveFactor)
                let normalizedLines = normalizedMultipvLines(
                    summary: normalizedSummary,
                    lines: lines.map { normalizeEngineLine($0, factor: perspectiveFactor) }
                )
                return EngineAnalysis(
                    depth: normalizedSummary.depth,
                    scoreCp: normalizedSummary.scoreCp,
                    scoreMate: normalizedSummary.scoreMate,
                    bestMove: normalizedSummary.bestMove,
                    pv: normalizedSummary.pv,
                    lines: normalizedLines
                )
            }

            // Backward compatibility if the existing binary still speaks the old protocol.
            if rawLine.hasPrefix("ok\t") {
                let legacy = try parseLegacyAnalysis(rawLine)
                return normalizeEngineAnalysis(legacy, lines: legacy.lines, factor: perspectiveFactor)
            }

            if rawLine.hasPrefix("err\t") {
                throw RepositoryError.failure(String(rawLine.dropFirst(4)))
            }
        }

        let stderr = String(decoding: stderrHandle.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stderr.isEmpty {
            throw RepositoryError.failure("Engine session terminated unexpectedly.")
        }
        throw RepositoryError.failure(stderr)
    }

    func shutdown() {
        if process.isRunning {
            try? writeLine("quit")
            process.waitUntilExit()
        }

        try? stdinHandle.close()
        try? stderrHandle.close()
    }

    private func writeLine(_ line: String) throws {
        guard let data = "\(line)\n".data(using: .utf8) else {
            throw RepositoryError.failure("Could not encode engine command.")
        }
        try stdinHandle.write(contentsOf: data)
    }

    private func parseMultipvSummary(_ line: String) throws -> EngineAnalysis {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count == 6, let depth = Int(columns[1]) else {
            throw RepositoryError.failure("Unexpected engine session output format: \(line)")
        }

        let cp = Int(columns[2])
        let mate = Int(columns[3])
        let bestMoveText = String(columns[4]).trimmingCharacters(in: .whitespacesAndNewlines)
        let pvText = String(columns[5]).trimmingCharacters(in: .whitespacesAndNewlines)

        return EngineAnalysis(
            depth: depth,
            scoreCp: cp,
            scoreMate: mate,
            bestMove: bestMoveText.isEmpty ? nil : bestMoveText,
            pv: pvText.isEmpty ? [] : pvText.split(separator: " ").map(String.init),
            lines: []
        )
    }

    private func parseMultipvLine(_ line: String) throws -> EngineLine {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count >= 6,
              let rank = Int(columns[1]),
              let depth = Int(columns[2]) else {
            throw RepositoryError.failure("Unexpected engine session line format: \(line)")
        }

        let cp = Int(columns[3])
        let mate = Int(columns[4])
        let pvText = String(columns[5]).trimmingCharacters(in: .whitespacesAndNewlines)
        let sanText: String
        if columns.count >= 7 {
            sanText = String(columns[6]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            sanText = pvText
        }

        return EngineLine(
            multipvRank: rank,
            depth: depth,
            scoreCp: cp,
            scoreMate: mate,
            pv: pvText.isEmpty ? [] : pvText.split(separator: " ").map(String.init),
            sanPv: sanText.isEmpty ? [] : sanText.split(separator: " ").map(String.init)
        )
    }

    private func normalizedMultipvLines(summary: EngineAnalysis, lines: [EngineLine]) -> [EngineLine] {
        let sorted = lines.sorted { lhs, rhs in
            if lhs.multipvRank == rhs.multipvRank {
                return lhs.depth > rhs.depth
            }
            return lhs.multipvRank < rhs.multipvRank
        }

        if !sorted.isEmpty {
            return sorted
        }

        return [
            EngineLine(
                multipvRank: 1,
                depth: summary.depth,
                scoreCp: summary.scoreCp,
                scoreMate: summary.scoreMate,
                pv: summary.pv,
                sanPv: summary.pv
            ),
        ]
    }

    private func parseLegacyAnalysis(_ line: String) throws -> EngineAnalysis {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count == 6, let depth = Int(columns[1]) else {
            throw RepositoryError.failure("Unexpected engine session output format: \(line)")
        }

        let cp = Int(columns[2])
        let mate = Int(columns[3])
        let bestMoveText = String(columns[4]).trimmingCharacters(in: .whitespacesAndNewlines)
        let pvText = String(columns[5]).trimmingCharacters(in: .whitespacesAndNewlines)
        let pv = pvText.isEmpty ? [] : pvText.split(separator: " ").map(String.init)

        return EngineAnalysis(
            depth: depth,
            scoreCp: cp,
            scoreMate: mate,
            bestMove: bestMoveText.isEmpty ? nil : bestMoveText,
            pv: pv,
            lines: [
                EngineLine(
                    multipvRank: 1,
                    depth: depth,
                    scoreCp: cp,
                    scoreMate: mate,
                    pv: pv,
                    sanPv: pv
                ),
            ]
        )
    }
}

struct RustEngineRepository: EngineRepository {
    private static let sessionStore = RustEngineSessionStore()
    private static let sessionMode = RustEngineSessionMode()

    func analyzePosition(
        enginePath: String,
        fen: String,
        depth: Int,
        multipv: Int
    ) async throws -> EngineAnalysis {
        let normalizedEnginePath = RustBridge.expandTilde(enginePath).trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFen = fen.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedEnginePath.isEmpty else {
            throw RepositoryError.invalidInput("Engine path is required.")
        }
        guard !normalizedFen.isEmpty else {
            throw RepositoryError.invalidInput("FEN is required.")
        }
        guard FileManager.default.fileExists(atPath: normalizedEnginePath) else {
            throw RepositoryError.invalidInput("Engine binary does not exist at '\(normalizedEnginePath)'.")
        }

        let safeDepth = max(depth, 1)
        let safeMultipv = max(1, min(multipv, 3))
        let repoRoot = try RustBridge.repoRootURL()
        let binaryURL: URL

        do {
            binaryURL = try RustBridge.ensureBinary(repoRoot: repoRoot)
        } catch {
            guard RustBridge.canBuildBinary(repoRoot: repoRoot) else {
                throw error
            }
            try RustBridge.buildBinary(repoRoot: repoRoot)
            binaryURL = try RustBridge.ensureBinary(repoRoot: repoRoot)
        }

        if await Self.sessionMode.persistentSessionEnabled() {
            do {
                return try await Self.sessionStore.analyze(
                    repoRoot: repoRoot,
                    binaryURL: binaryURL,
                    enginePath: normalizedEnginePath,
                    fen: normalizedFen,
                    depth: safeDepth,
                    multipv: safeMultipv
                )
            } catch is EngineSessionTimeoutError {
                await Self.sessionMode.disablePersistentSession()
                return try analyzeWithOneShotProcess(
                    repoRoot: repoRoot,
                    binaryURL: binaryURL,
                    enginePath: normalizedEnginePath,
                    fen: normalizedFen,
                    depth: safeDepth,
                    multipv: safeMultipv
                )
            } catch {
                return try analyzeWithOneShotProcess(
                    repoRoot: repoRoot,
                    binaryURL: binaryURL,
                    enginePath: normalizedEnginePath,
                    fen: normalizedFen,
                    depth: safeDepth,
                    multipv: safeMultipv
                )
            }
        }

        return try analyzeWithOneShotProcess(
            repoRoot: repoRoot,
            binaryURL: binaryURL,
            enginePath: normalizedEnginePath,
            fen: normalizedFen,
            depth: safeDepth,
            multipv: safeMultipv
        )
    }

    private func analyzeWithOneShotProcess(
        repoRoot: URL,
        binaryURL: URL,
        enginePath: String,
        fen: String,
        depth: Int,
        multipv: Int
    ) throws -> EngineAnalysis {
        let args = [
            "analyze-multipv",
            enginePath,
            fen,
            "--depth",
            String(depth),
            "--multipv",
            String(multipv),
        ]
        let output = try RustBridge.runProcess(
            executableURL: binaryURL,
            arguments: args,
            workingDirectory: repoRoot
        )
        return try parseOneShotAnalysis(output, fen: fen)
    }

    private func parseOneShotAnalysis(_ output: String, fen: String) throws -> EngineAnalysis {
        let perspectiveFactor = whitePerspectiveFactor(for: fen)
        let rows = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        guard !rows.isEmpty else {
            throw RepositoryError.failure("Engine did not return analysis output.")
        }

        var summary: EngineAnalysis?
        var lines: [EngineLine] = []

        for row in rows {
            if row.hasPrefix("summary\t") {
                summary = try parseOneShotSummary(row)
                continue
            }

            if row.hasPrefix("line\t") {
                lines.append(try parseOneShotLine(row))
                continue
            }
        }

        if let summary {
            let normalizedSummary = normalizeEngineAnalysis(summary, lines: [], factor: perspectiveFactor)
            let normalizedLines = normalizedMultipvLines(
                summary: normalizedSummary,
                lines: lines.map { normalizeEngineLine($0, factor: perspectiveFactor) }
            )
            return EngineAnalysis(
                depth: normalizedSummary.depth,
                scoreCp: normalizedSummary.scoreCp,
                scoreMate: normalizedSummary.scoreMate,
                bestMove: normalizedSummary.bestMove,
                pv: normalizedSummary.pv,
                lines: normalizedLines
            )
        }

        // Backward compatibility for old analyze output:
        // depth\tcp\tmate\tbestmove\tpv
        guard let legacyLine = rows.last else {
            throw RepositoryError.failure("Engine did not return analysis output.")
        }
        let legacy = try parseLegacyOneShotSummary(legacyLine)
        return normalizeEngineAnalysis(legacy, lines: legacy.lines, factor: perspectiveFactor)
    }

    private func parseOneShotSummary(_ line: String) throws -> EngineAnalysis {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count == 6, let depth = Int(columns[1]) else {
            throw RepositoryError.failure("Unexpected engine output format: \(line)")
        }

        let cp = Int(columns[2])
        let mate = Int(columns[3])
        let bestMoveText = String(columns[4]).trimmingCharacters(in: .whitespacesAndNewlines)
        let pvText = String(columns[5]).trimmingCharacters(in: .whitespacesAndNewlines)

        return EngineAnalysis(
            depth: depth,
            scoreCp: cp,
            scoreMate: mate,
            bestMove: bestMoveText.isEmpty ? nil : bestMoveText,
            pv: pvText.isEmpty ? [] : pvText.split(separator: " ").map(String.init),
            lines: []
        )
    }

    private func parseOneShotLine(_ line: String) throws -> EngineLine {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count >= 6,
              let rank = Int(columns[1]),
              let depth = Int(columns[2]) else {
            throw RepositoryError.failure("Unexpected engine line output format: \(line)")
        }

        let cp = Int(columns[3])
        let mate = Int(columns[4])
        let pvText = String(columns[5]).trimmingCharacters(in: .whitespacesAndNewlines)
        let sanText: String
        if columns.count >= 7 {
            sanText = String(columns[6]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            sanText = pvText
        }

        return EngineLine(
            multipvRank: rank,
            depth: depth,
            scoreCp: cp,
            scoreMate: mate,
            pv: pvText.isEmpty ? [] : pvText.split(separator: " ").map(String.init),
            sanPv: sanText.isEmpty ? [] : sanText.split(separator: " ").map(String.init)
        )
    }

    private func normalizedMultipvLines(summary: EngineAnalysis, lines: [EngineLine]) -> [EngineLine] {
        let sorted = lines.sorted { lhs, rhs in
            if lhs.multipvRank == rhs.multipvRank {
                return lhs.depth > rhs.depth
            }
            return lhs.multipvRank < rhs.multipvRank
        }

        if !sorted.isEmpty {
            return sorted
        }

        return [
            EngineLine(
                multipvRank: 1,
                depth: summary.depth,
                scoreCp: summary.scoreCp,
                scoreMate: summary.scoreMate,
                pv: summary.pv,
                sanPv: summary.pv
            ),
        ]
    }

    private func parseLegacyOneShotSummary(_ line: String) throws -> EngineAnalysis {
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard columns.count == 5, let depth = Int(columns[0]) else {
            throw RepositoryError.failure("Unexpected engine output format: \(line)")
        }

        let cp = Int(columns[1])
        let mate = Int(columns[2])
        let bestMoveText = String(columns[3]).trimmingCharacters(in: .whitespacesAndNewlines)
        let pvText = String(columns[4]).trimmingCharacters(in: .whitespacesAndNewlines)
        let pv = pvText.isEmpty ? [] : pvText.split(separator: " ").map(String.init)

        return EngineAnalysis(
            depth: depth,
            scoreCp: cp,
            scoreMate: mate,
            bestMove: bestMoveText.isEmpty ? nil : bestMoveText,
            pv: pv,
            lines: [
                EngineLine(
                    multipvRank: 1,
                    depth: depth,
                    scoreCp: cp,
                    scoreMate: mate,
                    pv: pv,
                    sanPv: pv
                ),
            ]
        )
    }
}
