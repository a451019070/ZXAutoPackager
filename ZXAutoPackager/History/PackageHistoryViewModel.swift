//
//  PackageHistoryViewModel.swift
//  ZXAutoPackager
//
//  Created by ZX on 2026/10/15.
//

import Combine
import Foundation

@MainActor
final class PackageHistoryViewModel: ObservableObject {
    @Published private(set) var packageHistory: [PackageHistoryRecord] = []
    @Published private(set) var historyError: String?

    private let historyStore: PackageHistoryStore

    init(historyStore: PackageHistoryStore? = nil) {
        self.historyStore = historyStore ?? PackageHistoryStore()
        reloadHistory()
    }

    private func reloadHistory() {
        do {
            packageHistory = try historyStore.load()
            historyError = nil
        } catch {
            historyError = "读取打包历史失败：\(error.localizedDescription)"
        }
    }

    static func recordPackage(_ record: PackageHistoryRecord,
                              historyStore: PackageHistoryStore? = nil) throws {
        let historyStore = historyStore ?? PackageHistoryStore()
        let updated = [record] + (try historyStore.load())
        try historyStore.save(updated)
    }

    func recordSymbolUpload(recordID: UUID, result: SymbolUploadResult) throws {
        var updated = try historyStore.load()
        guard let index = updated.firstIndex(where: { $0.id == recordID }) else {
            throw SymbolUploadError.invalid("历史记录已不存在，无法保存上传结果。")
        }
        var uploads = updated[index].symbolUploads ?? [:]
        uploads[result.providerID] = result.completedAt
        updated[index].symbolUploads = uploads
        try historyStore.save(updated)
        packageHistory = updated
    }
}
