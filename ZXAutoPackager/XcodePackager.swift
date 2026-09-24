import Foundation

final class BuildCancellationController: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func register(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()

        if shouldTerminate, process.isRunning {
            process.terminate()
        }
    }

    func clear(_ process: Process) {
        lock.lock()
        if self.process === process {
            self.process = nil
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let runningProcess = process
        lock.unlock()

        if let runningProcess, runningProcess.isRunning {
            runningProcess.terminate()
        }
    }
}

private struct CommandResult {
    let status: Int32
    let output: String
}

nonisolated struct XcodeBuildVersion: Sendable, Equatable {
    let marketingVersion: String
    let currentProjectVersion: String
}

nonisolated enum XcodePackager {
    private struct BuildSettingsEntry: Decodable {
        let target: String?
        let buildSettings: [String: String]
    }

    static func listSchemes(containerPath: String) throws -> [String] {
        let directoryURL = URL(fileURLWithPath: containerPath, isDirectory: true)
        let containerURL = try findXcodeContainer(in: directoryURL)
        let result = try runXcodebuild(
            try arguments(for: containerURL) + ["-list", "-json"],
            cancellation: BuildCancellationController(),
            onOutput: { _ in }
        )
        guard result.status == 0 else {
            throw PackageError.commandFailed(result.status, result.output)
        }
        return try parseSchemes(from: result.output)
    }

    static func parseSchemes(from output: String) throws -> [String] {
        guard let start = output.firstIndex(of: "{"),
              let end = output.lastIndex(of: "}"), start <= end else {
            throw PackageError.invalidInput("无法解析 Xcode Scheme 列表。")
        }
        let data = Data(output[start...end].utf8)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = (root["workspace"] ?? root["project"]) as? [String: Any],
              let schemes = container["schemes"] as? [String] else {
            throw PackageError.invalidInput("无法解析 Xcode Scheme 列表。")
        }
        return schemes
    }

    static func readBuildVersion(
        containerPath: String,
        scheme: String,
        configuration: String,
        platform: PackagePlatform,
        cancellation: BuildCancellationController
    ) throws -> XcodeBuildVersion {
        guard !cancellation.isCancelled else { throw PackageError.cancelled }

        let projectDirectoryURL = URL(fileURLWithPath: containerPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: projectDirectoryURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw PackageError.invalidInput("所选项目文件夹不存在。")
        }

        let containerURL = try findXcodeContainer(in: projectDirectoryURL)
        let result = try runXcodebuild(
            try arguments(for: containerURL) + [
                "-scheme", scheme,
                "-configuration", configuration,
                "-destination", platform.destination,
                "-showBuildSettings",
                "-json"
            ],
            cancellation: cancellation,
            onOutput: { _ in }
        )
        guard !cancellation.isCancelled else { throw PackageError.cancelled }
        guard result.status == 0 else {
            throw PackageError.commandFailed(result.status, result.output)
        }

        return try parseBuildVersion(from: result.output, scheme: scheme)
    }

    static func parseBuildVersion(from output: String, scheme: String) throws -> XcodeBuildVersion {
        guard let start = output.firstIndex(of: "["),
              let end = output.lastIndex(of: "]"),
              start <= end else {
            throw PackageError.invalidInput("无法解析 Xcode 构建设置。")
        }

        let json = String(output[start...end])
        let entries: [BuildSettingsEntry]
        do {
            entries = try JSONDecoder().decode([BuildSettingsEntry].self, from: Data(json.utf8))
        } catch {
            throw PackageError.invalidInput("无法解析 Xcode 构建设置：\(error.localizedDescription)")
        }

        let applicationEntries = entries.filter {
            $0.buildSettings["PRODUCT_TYPE"] == "com.apple.product-type.application" ||
                $0.buildSettings["WRAPPER_EXTENSION"] == "app"
        }
        let candidates = applicationEntries.isEmpty ? entries : applicationEntries
        let selected = candidates.first {
            $0.target == scheme ||
                $0.buildSettings["TARGET_NAME"] == scheme ||
                $0.buildSettings["PRODUCT_NAME"] == scheme
        } ?? candidates.first

        guard let settings = selected?.buildSettings else {
            throw PackageError.invalidInput("所选 Scheme 没有可用的 Xcode 构建设置。")
        }

        let version = settings["MARKETING_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let build = settings["CURRENT_PROJECT_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !version.isEmpty || !build.isEmpty else {
            throw PackageError.invalidInput(
                "Xcode 项目中未配置 MARKETING_VERSION 或 CURRENT_PROJECT_VERSION。"
            )
        }

        return XcodeBuildVersion(
            marketingVersion: version,
            currentProjectVersion: build
        )
    }

    static func package(
        _ request: PackageRequest,
        cancellation: BuildCancellationController,
        onOutput: @escaping @Sendable (String) -> Void
    ) throws -> PackageResult {
        guard !cancellation.isCancelled else { throw PackageError.cancelled }
        let fileManager = FileManager.default
        let projectDirectoryURL = URL(fileURLWithPath: request.containerPath, isDirectory: true)
        let outputURL = URL(fileURLWithPath: request.outputDirectory, isDirectory: true)

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: projectDirectoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw PackageError.invalidInput("所选项目文件夹不存在。")
        }

        let containerURL = try findXcodeContainer(in: projectDirectoryURL)
        let containerArguments = try arguments(for: containerURL)
        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ZXAutoPackager-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = temporaryRoot.appendingPathComponent("App.xcarchive", isDirectory: true)
        let exportURL = temporaryRoot.appendingPathComponent("Export", isDirectory: true)
        let exportOptionsURL = temporaryRoot.appendingPathComponent("ExportOptions.plist")
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let safeScheme = safeFileName(request.scheme)
        let safeVersion = safeFileName(request.versionNumber)
        let exportFolderName = "\(safeScheme) \(exportTimestamp())"
        let artifactDirectoryURL = outputURL.appendingPathComponent(exportFolderName, isDirectory: true)
        if fileManager.fileExists(atPath: artifactDirectoryURL.path) {
            try fileManager.removeItem(at: artifactDirectoryURL)
        }
        try fileManager.createDirectory(at: artifactDirectoryURL, withIntermediateDirectories: true)

        let buildLogURL = artifactDirectoryURL.appendingPathComponent("Build.log")
        fileManager.createFile(atPath: buildLogURL.path, contents: nil)
        let buildLogHandle = try FileHandle(forWritingTo: buildLogURL)
        defer { try? buildLogHandle.close() }

        onOutput("===== 开始归档 =====\n正在归档 \(request.scheme)（\(request.configuration)）…\n")
        try writeLog("===== 开始归档 =====\n", to: buildLogHandle)
        let archiveResult = try runXcodebuild(
            containerArguments + [
                "-scheme", request.scheme,
                "-configuration", request.configuration,
                "-destination", request.platform.destination,
                "-archivePath", archiveURL.path,
                "MARKETING_VERSION=\(request.versionNumber)",
                "CURRENT_PROJECT_VERSION=\(request.buildNumber)",
                "clean", "archive"
            ],
            cancellation: cancellation,
            onOutput: { chunk in
                try? writeLog(chunk, to: buildLogHandle)
            }
        )
        guard !cancellation.isCancelled else { throw PackageError.cancelled }
        guard archiveResult.status == 0 else {
            onOutput("===== 归档失败 =====\n\(importantErrors(from: archiveResult.output))\n")
            throw PackageError.commandFailed(archiveResult.status, archiveResult.output)
        }

        let baseName = "\(safeScheme)-v\(safeVersion)-\(request.configuration)-build\(request.buildNumber)"
        let artifactURL: URL
        let combinedLog: String
        if request.platform == .iOS {
            let signingInfo = try signingInfo(from: archiveURL)
            try makeExportOptionsPlist(at: exportOptionsURL, signingInfo: signingInfo)
            onOutput("===== 开始导出 IPA =====\n")
            try writeLog("\n===== 开始导出 IPA =====\n", to: buildLogHandle)
            let exportResult = try runXcodebuild([
                "-exportArchive",
                "-archivePath", archiveURL.path,
                "-exportPath", exportURL.path,
                "-exportOptionsPlist", exportOptionsURL.path
            ], cancellation: cancellation, onOutput: { chunk in
                onOutput(chunk)
                try? writeLog(chunk, to: buildLogHandle)
            })
            guard !cancellation.isCancelled else { throw PackageError.cancelled }
            combinedLog = archiveResult.output + "\n\n===== 导出 IPA =====\n" + exportResult.output
            guard exportResult.status == 0 else {
                throw PackageError.commandFailed(exportResult.status, combinedLog)
            }
            guard let ipaURL = findIPA(in: exportURL) else {
                throw PackageError.productNotFound(combinedLog)
            }
            artifactURL = artifactDirectoryURL.appendingPathComponent(baseName + ".ipa")
            try fileManager.copyItem(at: ipaURL, to: artifactURL)
            try copyExportMetadata(from: exportURL, to: artifactDirectoryURL)
        } else {
            guard let appURL = findArchivedApp(in: archiveURL) else {
                throw PackageError.invalidInput("归档中没有找到 macOS 应用，请确认 Scheme 的目标为 macOS App。")
            }
            artifactURL = artifactDirectoryURL.appendingPathComponent(baseName + ".zip")
            onOutput("===== 压缩 macOS 应用 =====\n")
            try writeLog("\n===== 压缩 macOS 应用 =====\n", to: buildLogHandle)
            let zipResult = try runCommand(
                executable: "/usr/bin/ditto",
                arguments: ["-c", "-k", "--sequesterRsrc", "--keepParent", appURL.path, artifactURL.path],
                cancellation: cancellation,
                onOutput: { chunk in
                    onOutput(chunk)
                    try? writeLog(chunk, to: buildLogHandle)
                }
            )
            guard !cancellation.isCancelled else { throw PackageError.cancelled }
            combinedLog = archiveResult.output + "\n\n===== 压缩 macOS 应用 =====\n" + zipResult.output
            guard zipResult.status == 0 else {
                throw PackageError.commandFailed(zipResult.status, combinedLog)
            }
        }

        let fileAttributes = try fileManager.attributesOfItem(atPath: artifactURL.path)
        let fileSize = (fileAttributes[.size] as? NSNumber)?.int64Value ?? 0

        return PackageResult(
            artifactPath: artifactURL.path,
            fileSize: fileSize,
            versionNumber: request.versionNumber,
            buildNumber: request.buildNumber,
            configuration: request.configuration,
            log: combinedLog
        )
    }

    private static func runXcodebuild(
        _ arguments: [String],
        cancellation: BuildCancellationController,
        onOutput: @escaping @Sendable (String) -> Void
    ) throws -> CommandResult {
        try runCommand(
            executable: "/usr/bin/xcrun",
            arguments: ["xcodebuild"] + arguments,
            cancellation: cancellation,
            onOutput: onOutput
        )
    }

    private static func runCommand(
        executable: String,
        arguments: [String],
        cancellation: BuildCancellationController? = nil,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) throws -> CommandResult {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        try process.run()
        cancellation?.register(process)
        defer { cancellation?.clear(process) }

        var outputData = Data()
        let handle = outputPipe.fileHandleForReading
        while true {
            let data = handle.availableData
            guard !data.isEmpty else { break }
            outputData.append(data)
            onOutput?(String(decoding: data, as: UTF8.self))
        }
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self)
        )
    }

    static func findArchivedApp(in archiveURL: URL) -> URL? {
        let applicationsURL = archiveURL
            .appendingPathComponent("Products", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
        guard let applications = try? FileManager.default.contentsOfDirectory(
            at: applicationsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return applications
            .filter { $0.pathExtension.lowercased() == "app" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .first
    }

    private struct SigningInfo {
        let bundleIdentifier: String
        let teamIdentifier: String
        let profileName: String
    }

    private static func signingInfo(from archiveURL: URL) throws -> SigningInfo {
        let applicationsURL = archiveURL
            .appendingPathComponent("Products", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
        let applications = try FileManager.default.contentsOfDirectory(
            at: applicationsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        guard let appURL = applications.first(where: { $0.pathExtension == "app" }) else {
            throw PackageError.invalidInput("归档中没有找到应用程序。")
        }

        let infoPlistURL = appURL.appendingPathComponent("Info.plist")
        let infoData = try Data(contentsOf: infoPlistURL)
        guard let info = try PropertyListSerialization.propertyList(
            from: infoData,
            options: [],
            format: nil
        ) as? [String: Any],
              let bundleIdentifier = info["CFBundleIdentifier"] as? String else {
            throw PackageError.invalidInput("无法读取归档应用的 Bundle ID。")
        }

        let profileURL = appURL.appendingPathComponent("embedded.mobileprovision")
        let profileResult = try runCommand(
            executable: "/usr/bin/security",
            arguments: ["cms", "-D", "-i", profileURL.path]
        )
        guard profileResult.status == 0,
              let profileData = profileResult.output.data(using: .utf8),
              let profile = try PropertyListSerialization.propertyList(
                from: profileData,
                options: [],
                format: nil
              ) as? [String: Any],
              let profileName = profile["Name"] as? String,
              let teamIdentifiers = profile["TeamIdentifier"] as? [String],
              let teamIdentifier = teamIdentifiers.first else {
            throw PackageError.invalidInput("无法读取归档内的 Provisioning Profile 签名信息。")
        }

        return SigningInfo(
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            profileName: profileName
        )
    }

    private static func makeExportOptionsPlist(
        at url: URL,
        signingInfo: SigningInfo
    ) throws {
        let options: [String: Any] = [
            "destination": "export",
            "method": "debugging",
            "signingCertificate": "Apple Development",
            "signingStyle": "manual",
            "teamID": signingInfo.teamIdentifier,
            "provisioningProfiles": [
                signingInfo.bundleIdentifier: signingInfo.profileName
            ],
            "stripSwiftSymbols": true,
            "thinning": "<none>"
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: options,
            format: .xml,
            options: 0
        )
        try data.write(to: url, options: .atomic)
    }

    private static func findIPA(in directoryURL: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let url as URL in enumerator where url.pathExtension.lowercased() == "ipa" {
            return url
        }
        return nil
    }

    private static func arguments(for containerURL: URL) throws -> [String] {
        switch containerURL.pathExtension.lowercased() {
        case "xcworkspace": return ["-workspace", containerURL.path]
        case "xcodeproj": return ["-project", containerURL.path]
        default: throw PackageError.invalidInput("请选择包含 .xcodeproj 或 .xcworkspace 的项目目录。")
        }
    }

    private static func findXcodeContainer(in directoryURL: URL) throws -> URL {
        let items = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        if let workspace = items
            .filter({ $0.pathExtension.lowercased() == "xcworkspace" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first {
            return workspace
        }

        if let project = items
            .filter({ $0.pathExtension.lowercased() == "xcodeproj" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .first {
            return project
        }

        throw PackageError.invalidInput(
            "所选文件夹中没有找到 .xcworkspace 或 .xcodeproj，请选择 Xcode 项目的根目录。"
        )
    }

    private static func writeLog(_ value: String, to handle: FileHandle) throws {
        try handle.write(contentsOf: Data(value.utf8))
    }

    private static func importantErrors(from output: String) -> String {
        let importantLines = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                let lowercased = line.lowercased()
                return lowercased.contains("error:") ||
                    lowercased.contains("archive failed") ||
                    lowercased.contains("provisioning profile") ||
                    lowercased.contains("code signing")
            }
        return importantLines.suffix(20).joined(separator: "\n")
    }

    private static func copyExportMetadata(from sourceURL: URL, to destinationURL: URL) throws {
        let fileManager = FileManager.default
        for fileName in ["ExportOptions.plist", "Packaging.log", "DistributionSummary.plist"] {
            let sourceFileURL = sourceURL.appendingPathComponent(fileName)
            guard fileManager.fileExists(atPath: sourceFileURL.path) else { continue }
            try fileManager.copyItem(
                at: sourceFileURL,
                to: destinationURL.appendingPathComponent(fileName)
            )
        }
    }

    private static func exportTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        return formatter.string(from: Date())
    }

    private static func safeFileName(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-")
    }
}
