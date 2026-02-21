import Foundation

struct WorkspaceDatabaseRecord: Codable, Equatable, Sendable {
    let id: UUID
    var label: String
    var path: String
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date
}

struct WorkspaceStore {
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(url: URL = WorkspaceStore.defaultURL()) {
        self.url = url
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ChessPrepApp", isDirectory: true)
        return base.appendingPathComponent("workspace-databases.json")
    }

    func load() -> [WorkspaceDatabaseRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? decoder.decode([WorkspaceDatabaseRecord].self, from: data)) ?? []
    }

    func save(_ records: [WorkspaceDatabaseRecord]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(records)
        try data.write(to: url, options: .atomic)
    }
}
