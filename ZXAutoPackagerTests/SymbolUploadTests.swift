import Foundation
import Testing
@testable import ZXAutoPackager

struct SymbolUploadTests {
    @Test func validatesSymbolsAndRejectsEmptyDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: (any Error).self) { try SymbolFiles.validate(root) }
        let symbol = root.appendingPathComponent("App.app.dSYM")
        let dwarf = symbol.appendingPathComponent("Contents/Resources/DWARF")
        try FileManager.default.createDirectory(at: dwarf, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try SymbolFiles.validate(root) }
        try Data("symbols".utf8).write(to: dwarf.appendingPathComponent("App"))
        try SymbolFiles.validate(root)
        try SymbolFiles.validate(symbol)
        #expect(SymbolFiles.defaultDirectory(artifactPath: root.appendingPathComponent("App.ipa").path) == root.appendingPathComponent("dSYMs", isDirectory: true))
    }

    @Test func buglyArgumentsKeepPathsAndCredentialsAsSeparateArguments() {
        let request = SymbolUploadRequest(symbolURL: URL(fileURLWithPath: "/tmp/My App/dSYMs"),
                                          version: "1.2.3", appID: "app", appKey: "secret key",
                                          toolURL: URL(fileURLWithPath: "/tmp/My Tools/buglyqq-upload-symbol.jar"))
        let arguments = BuglySymbolUploader.arguments(for: request)
        #expect(arguments == ["-jar", request.toolURL.path, "-appid", "app", "-appkey", "secret key",
                              "-version", "1.2.3",
                              "-platform", "IOS", "-inputSymbol", request.symbolURL.path])
    }

    @MainActor @Test func historySupportsLegacyJSONAndProviderResults() throws {
        var record = PackageHistoryRecord(id: UUID(), completedAt: Date(), scheme: "App", platform: "iOS",
                                          artifactPath: "/tmp/App.ipa", fileSize: 100, version: "1.0", buildNumber: 1,
                                          configuration: "Release", durationSeconds: 10, downloadURL: nil)
        let legacyData = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(PackageHistoryRecord.self, from: legacyData).symbolUploads == nil)
        record.symbolUploads = ["bugly": Date(timeIntervalSince1970: 100), "future-provider": Date(timeIntervalSince1970: 200)]
        let restored = try JSONDecoder().decode(PackageHistoryRecord.self, from: JSONEncoder().encode(record))
        #expect(restored.symbolUploads == record.symbolUploads)
    }
}
