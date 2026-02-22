import Foundation
import os

@MainActor
final class TelemetryService {
    static let shared = TelemetryService()

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "ChessPrepApp", category: "telemetry")
    private let encoder: JSONEncoder

    private let telemetryEnabledKey = "telemetry.enabled"
    private let installIDKey = "telemetry.install_id"

    private struct EventRecord: Encodable {
        let timestamp: String
        let event: String
        let installID: String
        let appVersion: String
        let appBuild: String
        let properties: [String: String]
    }

    private struct SessionMarker: Encodable {
        let startedAt: String
    }

    init(defaults: UserDefaults = .standard, fileManager: FileManager = .default) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
    }

    var isEnabled: Bool {
        isEnabledLocked()
    }

    var installID: String {
        installIDLocked()
    }

    var eventsLogPath: String {
        eventsLogURLLocked().path
    }

    func setEnabled(_ enabled: Bool) {
        let wasEnabled = isEnabledLocked()
        guard wasEnabled != enabled else { return }

        if wasEnabled {
            appendEventLocked(name: "telemetry_disabled", properties: [:])
        }

        defaults.set(enabled, forKey: telemetryEnabledKey)

        if enabled {
            appendEventLocked(name: "telemetry_enabled", properties: [:])
        }
    }

    func startSession() {
        let markerURL = sessionMarkerURLLocked()
        let hadUncleanExit = fileManager.fileExists(atPath: markerURL.path)

        if hadUncleanExit, isEnabledLocked() {
            appendEventLocked(name: "previous_session_unclean_exit", properties: [:])
        }

        writeSessionMarkerLocked()

        guard isEnabledLocked() else { return }
        appendEventLocked(
            name: "app_launch",
            properties: ["unclean_previous_session": hadUncleanExit ? "true" : "false"]
        )
    }

    func endSession() {
        if isEnabledLocked() {
            appendEventLocked(name: "app_exit", properties: [:])
        }
        try? fileManager.removeItem(at: sessionMarkerURLLocked())
    }

    func track(_ event: String, properties: [String: String] = [:]) {
        guard isEnabledLocked() else { return }
        appendEventLocked(name: event, properties: properties)
    }

    private func isEnabledLocked() -> Bool {
        (defaults.object(forKey: telemetryEnabledKey) as? Bool) ?? false
    }

    private func installIDLocked() -> String {
        if let existing = defaults.string(forKey: installIDKey),
           !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return existing
        }

        let created = UUID().uuidString.lowercased()
        defaults.set(created, forKey: installIDKey)
        return created
    }

    private func appVersionLocked() -> String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? shortVersion!
            : "dev"
    }

    private func appBuildLocked() -> String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        return build?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? build!
            : "dev"
    }

    private func telemetryDirectoryURLLocked() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let dir = base
            .appendingPathComponent("ChessPrepApp", isDirectory: true)
            .appendingPathComponent("telemetry", isDirectory: true)

        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create telemetry directory: \(error.localizedDescription, privacy: .public)")
        }

        return dir
    }

    private func sessionMarkerURLLocked() -> URL {
        telemetryDirectoryURLLocked().appendingPathComponent("session.marker.json", isDirectory: false)
    }

    private func eventsLogURLLocked() -> URL {
        telemetryDirectoryURLLocked().appendingPathComponent("events.jsonl", isDirectory: false)
    }

    private func writeSessionMarkerLocked() {
        let marker = SessionMarker(startedAt: iso8601(Date()))

        do {
            let data = try encoder.encode(marker)
            try data.write(to: sessionMarkerURLLocked(), options: .atomic)
        } catch {
            logger.error("Failed to write session marker: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func appendEventLocked(name: String, properties: [String: String]) {
        let record = EventRecord(
            timestamp: iso8601(Date()),
            event: name,
            installID: installIDLocked(),
            appVersion: appVersionLocked(),
            appBuild: appBuildLocked(),
            properties: properties
        )

        do {
            var data = try encoder.encode(record)
            data.append(0x0A)
            try appendDataLocked(data, to: eventsLogURLLocked())
        } catch {
            logger.error("Failed to encode telemetry event: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func appendDataLocked(_ data: Data, to url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            _ = fileManager.createFile(atPath: url.path, contents: Data())
        }

        let handle = try FileHandle(forWritingTo: url)
        defer {
            try? handle.close()
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
