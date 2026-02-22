import Foundation

struct RustRuntimeContext {
    let workingDirectory: URL
    let binaryURL: URL
    let canBuildFromSource: Bool
}

enum RustBridge {
    private static func sourceRepoRootURL() -> URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 {
            url.deleteLastPathComponent()
        }

        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Cargo.toml").path) else {
            return nil
        }

        return url
    }

    private static func fallbackWorkingDirectoryURL() -> URL {
        if let resourceURL = Bundle.main.resourceURL {
            return resourceURL
        }
        if let moduleResourceURL = Bundle.module.resourceURL {
            return moduleResourceURL
        }
        return FileManager.default.temporaryDirectory
    }

    static func repoRootURL() throws -> URL {
        if let sourceRepoRoot = sourceRepoRootURL() {
            return sourceRepoRoot
        }
        return fallbackWorkingDirectoryURL()
    }

    static func runtimeContext() throws -> RustRuntimeContext {
        let workingDirectory = try repoRootURL()
        let binary = try ensureBinary(repoRoot: workingDirectory)
        return RustRuntimeContext(
            workingDirectory: workingDirectory,
            binaryURL: binary,
            canBuildFromSource: canBuildBinary(repoRoot: workingDirectory)
        )
    }

    static func canBuildBinary(repoRoot: URL) -> Bool {
        FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Cargo.toml").path)
    }

    private static func bundledBackendBinaryURL() -> URL? {
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("Binaries/chess-prep-backend"),
            Bundle.main.resourceURL?.appendingPathComponent("chess-prep-backend"),
            Bundle.module.url(forResource: "chess-prep-backend", withExtension: nil),
            Bundle.module.url(forResource: "chess-prep-backend", withExtension: nil, subdirectory: "Binaries"),
        ]

        for candidate in candidates.compactMap({ $0 }) {
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            ensureExecutablePermissions(url: candidate)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    static func bundledEnginePath() -> String? {
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("Engines/stockfish"),
            Bundle.main.resourceURL?.appendingPathComponent("stockfish"),
            Bundle.module.url(forResource: "stockfish", withExtension: nil),
            Bundle.module.url(forResource: "stockfish", withExtension: nil, subdirectory: "Engines"),
        ]

        for candidate in candidates.compactMap({ $0 }) {
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            ensureExecutablePermissions(url: candidate)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.path
            }
        }

        return nil
    }

    private static func ensureExecutablePermissions(url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if FileManager.default.isExecutableFile(atPath: url.path) {
            return
        }

        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            // Best effort only; caller validates executability.
        }
    }

    static func binaryURL(repoRoot: URL) -> URL {
        if let bundledBackend = bundledBackendBinaryURL() {
            return bundledBackend
        }

        let releaseBinary = repoRoot.appendingPathComponent("target/release/chess-prep")
        if FileManager.default.fileExists(atPath: releaseBinary.path) {
            return releaseBinary
        }

        return repoRoot.appendingPathComponent("target/debug/chess-prep")
    }

    static func ensureBinary(repoRoot: URL) throws -> URL {
        if let bundledBackend = bundledBackendBinaryURL() {
            return bundledBackend
        }

        let binary = binaryURL(repoRoot: repoRoot)
        if !FileManager.default.fileExists(atPath: binary.path) {
            try buildBinary(repoRoot: repoRoot)
        }
        return binary
    }

    static func buildBinary(repoRoot: URL) throws {
        guard canBuildBinary(repoRoot: repoRoot) else {
            throw RepositoryError.failure(
                "Rust backend binary is missing and local source build is unavailable."
            )
        }

        _ = try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "cargo",
                "build",
                "--manifest-path",
                repoRoot.appendingPathComponent("Cargo.toml").path,
            ],
            workingDirectory: repoRoot
        )
    }

    static func ensureDbExists(binaryURL: URL, dbPath: String, repoRoot: URL) throws {
        try ensureDbExists(binaryURL: binaryURL, dbPath: dbPath, workingDirectory: repoRoot)
    }

    static func ensureDbExists(binaryURL: URL, dbPath: String, workingDirectory: URL) throws {
        if !FileManager.default.fileExists(atPath: dbPath) {
            _ = try runProcess(
                executableURL: binaryURL,
                arguments: ["init", dbPath],
                workingDirectory: workingDirectory
            )
        }
    }

    static func runProcess(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL
    ) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                throw RepositoryError.failure("Rust command failed: \(arguments.joined(separator: " "))")
            }
            throw RepositoryError.failure(message)
        }

        return stdout
    }

    static func runProcessStreaming(
        executableURL: URL,
        arguments: [String],
        workingDirectory: URL,
        onStdoutLine: @escaping @Sendable (String) -> Void
    ) throws -> String {
        final class StreamAccumulator: @unchecked Sendable {
            private let lock = NSLock()
            private let newline = Data([0x0A])
            private var stdoutData = Data()
            private var stderrData = Data()
            private var pendingLineData = Data()
            private let onStdoutLine: @Sendable (String) -> Void

            init(onStdoutLine: @escaping @Sendable (String) -> Void) {
                self.onStdoutLine = onStdoutLine
            }

            func appendStdout(_ data: Data) {
                guard !data.isEmpty else { return }
                var lines: [String] = []

                lock.lock()
                stdoutData.append(data)
                pendingLineData.append(data)
                while let range = pendingLineData.range(of: newline) {
                    let lineData = pendingLineData.subdata(in: pendingLineData.startIndex..<range.lowerBound)
                    pendingLineData.removeSubrange(pendingLineData.startIndex...range.lowerBound)
                    if let line = String(data: lineData, encoding: .utf8) {
                        lines.append(line)
                    }
                }
                lock.unlock()

                for line in lines {
                    onStdoutLine(line)
                }
            }

            func appendStderr(_ data: Data) {
                guard !data.isEmpty else { return }
                lock.lock()
                stderrData.append(data)
                lock.unlock()
            }

            func finalize(stdoutTail: Data, stderrTail: Data) {
                var lines: [String] = []
                var trailingLine: String?

                lock.lock()
                stdoutData.append(stdoutTail)
                pendingLineData.append(stdoutTail)
                while let range = pendingLineData.range(of: newline) {
                    let lineData = pendingLineData.subdata(in: pendingLineData.startIndex..<range.lowerBound)
                    pendingLineData.removeSubrange(pendingLineData.startIndex...range.lowerBound)
                    if let line = String(data: lineData, encoding: .utf8) {
                        lines.append(line)
                    }
                }
                if !pendingLineData.isEmpty {
                    trailingLine = String(data: pendingLineData, encoding: .utf8)
                }
                pendingLineData.removeAll(keepingCapacity: false)
                stderrData.append(stderrTail)
                lock.unlock()

                for line in lines {
                    onStdoutLine(line)
                }
                if let trailingLine {
                    onStdoutLine(trailingLine)
                }
            }

            func outputs() -> (stdout: String, stderr: String) {
                lock.lock()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                lock.unlock()
                return (stdout, stderr)
            }
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let accumulator = StreamAccumulator(onStdoutLine: onStdoutLine)

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            accumulator.appendStdout(data)
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            accumulator.appendStderr(data)
        }

        try process.run()
        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let stdoutTail = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrTail = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        accumulator.finalize(stdoutTail: stdoutTail, stderrTail: stderrTail)
        let (stdout, stderr) = accumulator.outputs()

        guard process.terminationStatus == 0 else {
            let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if message.isEmpty {
                throw RepositoryError.failure("Rust command failed: \(arguments.joined(separator: " "))")
            }
            throw RepositoryError.failure(message)
        }

        return stdout
    }

    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    static func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func stableUUID(for id: Int64) -> UUID {
        let hex = String(format: "%016llx", UInt64(bitPattern: id))
        let part4 = String(hex.prefix(4))
        let part5 = String(hex.suffix(12))
        let uuidString = "00000000-0000-0000-\(part4)-\(part5)"
        return UUID(uuidString: uuidString) ?? UUID()
    }

    static func stableUUID(for key: String) -> UUID {
        // Deterministic 128-bit digest from UTF-8 bytes.
        let bytes = Array(key.utf8)
        var high: UInt64 = 0xcbf29ce484222325
        var low: UInt64 = 0x84222325cbf29ce4

        for byte in bytes {
            high ^= UInt64(byte)
            high &*= 0x100000001b3
        }

        for byte in bytes.reversed() {
            low ^= UInt64(byte)
            low &*= 0x100000001b3
        }

        let hex = String(format: "%016llx%016llx", high, low)
        let uuidString = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: uuidString) ?? UUID()
    }
}
