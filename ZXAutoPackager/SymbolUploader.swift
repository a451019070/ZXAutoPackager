import Foundation
import Security

nonisolated struct SymbolUploadRequest: Sendable {
    let symbolURL: URL
    let version: String
    let appID: String
    let appKey: String
    let toolURL: URL
}

nonisolated struct SymbolUploadResult: Sendable {
    let providerID: String
    let completedAt: Date
    let output: String
}

nonisolated protocol SymbolUploader: Sendable {
    var providerID: String { get }
    func upload(_ request: SymbolUploadRequest) async throws -> SymbolUploadResult
}

nonisolated enum SymbolUploadError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

nonisolated enum SymbolFiles {
    static func defaultDirectory(artifactPath: String) -> URL {
        URL(fileURLWithPath: artifactPath).deletingLastPathComponent()
            .appendingPathComponent("dSYMs", isDirectory: true)
    }

    static func validate(_ url: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SymbolUploadError.invalid("dSYM 目录不存在，请重新选择符号文件。")
        }
        let candidates: [URL]
        if url.pathExtension.lowercased() == "dsym" {
            candidates = [url]
        } else {
            candidates = try manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "dsym" }
        }
        guard !candidates.isEmpty else {
            throw SymbolUploadError.invalid("所选目录中没有 dSYM 文件。请选择 .dSYM 或包含它们的目录。")
        }
        for candidate in candidates {
            let dwarf = candidate.appendingPathComponent("Contents/Resources/DWARF", isDirectory: true)
            let files = try manager.contentsOfDirectory(at: dwarf, includingPropertiesForKeys: [.isRegularFileKey])
            guard try files.contains(where: { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }) else {
                throw SymbolUploadError.invalid("dSYM 缺少 DWARF 符号数据：\(candidate.lastPathComponent)")
            }
        }
    }
}

nonisolated struct BuglySymbolUploader: SymbolUploader {
    let providerID = "bugly"

    static func arguments(for request: SymbolUploadRequest) -> [String] {
        ["-jar", request.toolURL.path, "-appid", request.appID, "-appkey", request.appKey,
         "-version", request.version, "-platform", "IOS", "-inputSymbol", request.symbolURL.path]
    }

    func upload(_ request: SymbolUploadRequest) async throws -> SymbolUploadResult {
        try SymbolFiles.validate(request.symbolURL)
        guard !request.appID.isEmpty, !request.appKey.isEmpty else {
            throw SymbolUploadError.invalid("请填写 Bugly App ID 和 App Key。")
        }
        guard request.toolURL.pathExtension.lowercased() == "jar",
              FileManager.default.isReadableFile(atPath: request.toolURL.path) else {
            throw SymbolUploadError.invalid("请选择 Bugly 官方 buglyqq-upload-symbol.jar 工具。")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SymbolUpload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let logURL = temporary.appendingPathComponent("upload.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/java")
        process.arguments = Self.arguments(for: request)
        process.currentDirectoryURL = temporary
        process.standardOutput = log
        process.standardError = log
        try Task.checkCancellation()
        try process.run()
        do {
            while process.isRunning {
                try await Task.sleep(for: .milliseconds(200))
            }
        } catch {
            if process.isRunning { process.terminate() }
            while process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
            throw error
        }
        try Task.checkCancellation()
        let output = String(decoding: try Data(contentsOf: logURL), as: UTF8.self)
            .replacingOccurrences(of: request.appKey, with: "[已隐藏]")
        guard process.terminationStatus == 0 else {
            throw SymbolUploadError.invalid("Bugly 工具执行失败（\(process.terminationStatus)）。\n\(output.suffix(6000))")
        }
        guard !output.localizedCaseInsensitiveContains("upload failed"),
              !output.localizedCaseInsensitiveContains("upload fail"),
              !output.localizedCaseInsensitiveContains("exception"),
              !output.contains("上传失败") else {
            throw SymbolUploadError.invalid("Bugly 工具报告错误：\n\(output.suffix(6000))")
        }
        return SymbolUploadResult(providerID: providerID, completedAt: Date(), output: String(output.suffix(12000)))
    }
}

nonisolated enum SymbolCredentialStore {
    private static let service = "ZXAutoPackager.SymbolUpload"

    static func load(account: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SymbolUploadError.invalid("读取钥匙串失败（\(status)）。")
        }
        return String(decoding: data, as: UTF8.self)
    }

    static func save(_ value: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let insertStatus = SecItemAdd(item as CFDictionary, nil)
            guard insertStatus == errSecSuccess else {
                throw SymbolUploadError.invalid("保存 App Key 到钥匙串失败（\(insertStatus)）。")
            }
        } else if status != errSecSuccess {
            throw SymbolUploadError.invalid("更新钥匙串失败（\(status)）。")
        }
    }
}
