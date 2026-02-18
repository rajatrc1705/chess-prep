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
