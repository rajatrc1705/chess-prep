import Foundation

enum RustBridge {
    static func repoRootURL() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 {
            url.deleteLastPathComponent()
        }

        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("Cargo.toml").path) else {
            throw RepositoryError.failure("Could not locate project root from Swift package path.")
        }

        return url
    }

    static func binaryURL(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent("target/debug/chess-prep")
    }

    static func ensureBinary(repoRoot: URL) throws -> URL {
        let binary = binaryURL(repoRoot: repoRoot)
        if !FileManager.default.fileExists(atPath: binary.path) {
            try buildBinary(repoRoot: repoRoot)
        }
        return binary
    }

    static func buildBinary(repoRoot: URL) throws {
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
        if !FileManager.default.fileExists(atPath: dbPath) {
            _ = try runProcess(
                executableURL: binaryURL,
                arguments: ["init", dbPath],
                workingDirectory: repoRoot
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
}
