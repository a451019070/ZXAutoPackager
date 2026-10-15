import Foundation
import Testing
@testable import ZXAutoPackager

@MainActor
struct PackageHistoryViewModelTests {
    @Test func recordsAndSymbolUploadsPersist() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PackageHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
        let viewModel = PackageHistoryViewModel(historyStore: store)
        #expect(viewModel.packageHistory.isEmpty)
        #expect(viewModel.historyError == nil)

        let older = record(completedAt: 100)
        let newer = record(completedAt: 200)
        try PackageHistoryViewModel.recordPackage(older, historyStore: store)
        #expect(viewModel.packageHistory.isEmpty)
        let opened = PackageHistoryViewModel(historyStore: store)
        #expect(opened.packageHistory.map(\.id) == [older.id])

        try PackageHistoryViewModel.recordPackage(newer, historyStore: store)
        #expect(opened.packageHistory.map(\.id) == [older.id])

        let completedAt = Date(timeIntervalSince1970: 300)
        try opened.recordSymbolUpload(recordID: older.id, result: SymbolUploadResult(
            providerID: "bugly", completedAt: completedAt, output: "uploaded"
        ))
        #expect(opened.packageHistory.map(\.id) == [newer.id, older.id])
        #expect(opened.packageHistory[1].symbolUploads?["bugly"] == completedAt)

        let restored = PackageHistoryViewModel(historyStore: store)
        #expect(restored.packageHistory.map(\.id) == [newer.id, older.id])
        #expect(restored.packageHistory[1].symbolUploads?["bugly"] == completedAt)
        #expect(restored.historyError == nil)
        #expect(throws: SymbolUploadError.self) {
            try restored.recordSymbolUpload(recordID: UUID(), result: SymbolUploadResult(
                providerID: "bugly", completedAt: completedAt, output: "uploaded"
            ))
        }
    }

    @Test func failedSaveDoesNotPublishUnsavedRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("not-a-directory")
        let store = PackageHistoryStore(fileURL: blocker.appendingPathComponent("history.json"))
        let viewModel = PackageHistoryViewModel(historyStore: store)
        try Data().write(to: blocker)

        #expect(throws: (any Error).self) {
            try PackageHistoryViewModel.recordPackage(record(completedAt: 100), historyStore: store)
        }

        #expect(viewModel.packageHistory.isEmpty)
        #expect(viewModel.historyError == nil)
    }

    @Test func invalidHistoryReportsLoadError() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("history.json")
        try Data("invalid json".utf8).write(to: fileURL)

        let viewModel = PackageHistoryViewModel(historyStore: PackageHistoryStore(fileURL: fileURL))

        #expect(viewModel.packageHistory.isEmpty)
        #expect(viewModel.historyError?.hasPrefix("读取打包历史失败：") == true)
    }

    private func record(completedAt: TimeInterval) -> PackageHistoryRecord {
        PackageHistoryRecord(
            id: UUID(), completedAt: Date(timeIntervalSince1970: completedAt), scheme: "App", platform: "iOS",
            artifactPath: "/tmp/App.ipa", fileSize: 1024, version: "1.0", buildNumber: 1,
            configuration: "Release", durationSeconds: 10, downloadURL: nil
        )
    }
}
