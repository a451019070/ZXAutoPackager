import Foundation

struct PackageHistoryRecord: Codable, Identifiable {
    let id: UUID
    let completedAt: Date
    let scheme: String
    let platform: String
    let artifactPath: String
    let fileSize: Int64
    let version: String
    let buildNumber: Int
    let configuration: String
    let durationSeconds: Int
    let downloadURL: String?

    var fileName: String { URL(fileURLWithPath: artifactPath).lastPathComponent }
    var fileSizeText: String { ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file) }
    var durationText: String {
        let minutes = durationSeconds / 60
        let seconds = durationSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct PackageHistoryStore {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZXAutoPackager", isDirectory: true)
            .appendingPathComponent("package-history.json")
    }

    func load() throws -> [PackageHistoryRecord] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let records = try JSONDecoder().decode([PackageHistoryRecord].self, from: Data(contentsOf: fileURL))
        return records.sorted { $0.completedAt > $1.completedAt }
    }

    func save(_ records: [PackageHistoryRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: fileURL, options: .atomic)
    }
}
