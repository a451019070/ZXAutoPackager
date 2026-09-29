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
        let schemeContainerURL = try findMainProject(in: directoryURL, workspaceURL: containerURL) ?? containerURL
        let result = try runXcodebuild(
            try arguments(for: schemeContainerURL) + ["-list", "-json"],
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

        let originalContainerURL = try findXcodeContainer(in: projectDirectoryURL)
        let manualProfile = try request.platform == .iOS ? request.signingProfileUUID.map(ManualSigningProfile.load) : nil
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ZXAutoPackager-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let containerArguments = try arguments(for: originalContainerURL)
        var signingBackup: (file: URL, contents: Data)?
        defer {
            if let signingBackup {
                try? signingBackup.contents.write(to: signingBackup.file, options: .atomic)
            }
        }
        if let manualProfile {
            signingBackup = try configureManualSigning(
                containerArguments: containerArguments, scheme: request.scheme,
                configuration: request.configuration, profile: manualProfile,
                buildRoot: projectDirectoryURL, cancellation: cancellation
            )
        }
        try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

        let archiveURL = temporaryRoot.appendingPathComponent("App.xcarchive", isDirectory: true)
        let exportURL = temporaryRoot.appendingPathComponent("Export", isDirectory: true)
        let exportOptionsURL = temporaryRoot.appendingPathComponent("ExportOptions.plist")

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
                "DEBUG_INFORMATION_FORMAT=dwarf-with-dsym",
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
            if let manualProfile {
                try manualProfile.validate(bundleID: signingInfo.bundleIdentifier)
                try validateArchivedSigning(
                    selected: manualProfile,
                    archivedTeamID: signingInfo.teamIdentifier,
                    archivedProfileName: signingInfo.profileName,
                    archivedProfileUUID: signingInfo.profileUUID
                )
            }
            try makeExportOptionsPlist(at: exportOptionsURL, signingInfo: signingInfo, manualProfile: manualProfile)
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
            try copyArchivedDSYMs(from: archiveURL, to: artifactDirectoryURL)
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

        let archivesURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Developer/Xcode/Archives", isDirectory: true)
        let savedArchiveURL = try saveXcodeArchive(from: archiveURL, for: request.scheme, in: archivesURL)
        onOutput("归档已保存：\(savedArchiveURL.path)\n")
        try writeLog("\n归档已保存：\(savedArchiveURL.path)\n", to: buildLogHandle)

        return PackageResult(
            artifactPath: artifactURL.path,
            fileSize: fileSize,
            versionNumber: request.versionNumber,
            buildNumber: request.buildNumber,
            configuration: request.configuration,
            log: combinedLog
        )
    }

    private static func configureManualSigning(
        containerArguments: [String], scheme: String, configuration: String,
        profile: ManualSigningProfile, buildRoot: URL,
        cancellation: BuildCancellationController
    ) throws -> (file: URL, contents: Data) {
        let result = try runXcodebuild(
            containerArguments + ["-scheme", scheme, "-configuration", configuration,
                                  "-destination", PackagePlatform.iOS.destination, "-showBuildSettings", "-json"],
            cancellation: cancellation, onOutput: { _ in }
        )
        guard !cancellation.isCancelled else { throw PackageError.cancelled }
        guard result.status == 0 else { throw PackageError.commandFailed(result.status, result.output) }
        let bundleID = try manualSigningBundleID(from: result.output)
        try profile.validate(bundleID: bundleID)
        guard let start = result.output.firstIndex(of: "["),
              let end = result.output.lastIndex(of: "]"),
              let entries = try JSONSerialization.jsonObject(with: Data(result.output[start...end].utf8)) as? [[String: Any]],
              let app = entries.first(where: {
                  ($0["buildSettings"] as? [String: String])?["PRODUCT_TYPE"] == "com.apple.product-type.application"
              }),
              let settings = app["buildSettings"] as? [String: String],
              let targetName = app["target"] as? String,
              let projectPath = settings["PROJECT_FILE_PATH"] else {
            throw PackageError.invalidInput("无法定位 App 目标的 Xcode 工程。")
        }
        let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
        let resolvedRoot = buildRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedProject = projectURL.resolvingSymlinksInPath().standardizedFileURL
        let pbxproj = projectURL.appendingPathComponent("project.pbxproj")
        let resolvedPBXProj = pbxproj.resolvingSymlinksInPath().standardizedFileURL
        guard projectURL.pathExtension == "xcodeproj",
              resolvedProject.path.hasPrefix(resolvedRoot.path + "/"),
              resolvedPBXProj.path.hasPrefix(resolvedRoot.path + "/") else {
            throw PackageError.invalidInput("App 目标不在所选项目目录中，已停止签名设置修改。")
        }
        let original = try Data(contentsOf: pbxproj)
        let changed = try manuallySignedProject(
            original, targetName: targetName,
            configuration: configuration, profile: profile
        )
        try changed.write(to: pbxproj, options: .atomic)
        return (pbxproj, original)
    }

    static func manuallySignedProject(
        _ data: Data, targetName: String, configuration: String,
        profile: ManualSigningProfile
    ) throws -> Data {
        guard var project = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil
        ) as? [String: Any],
              var objects = project["objects"] as? [String: [String: Any]] else {
            throw PackageError.invalidInput("无法解析 App 工程的构建设置。")
        }
        let targets = objects.filter { $0.value["isa"] as? String == "PBXNativeTarget" &&
            $0.value["name"] as? String == targetName &&
            $0.value["productType"] as? String == "com.apple.product-type.application" }
        guard targets.count == 1,
              let configListID = targets.first?.value["buildConfigurationList"] as? String,
              let configList = objects[configListID],
              let configIDs = configList["buildConfigurations"] as? [String] else {
            throw PackageError.invalidInput("无法定位唯一的 App 目标签名设置。")
        }
        let matches = configIDs.filter { objects[$0]?["name"] as? String == configuration }
        guard matches.count == 1, let configID = matches.first,
              var config = objects[configID] else {
            throw PackageError.invalidInput("无法定位 App 目标的 \(configuration) 构建配置。")
        }
        var settings = config["buildSettings"] as? [String: Any] ?? [:]
        settings["CODE_SIGN_STYLE"] = "Manual"
        settings["DEVELOPMENT_TEAM"] = profile.teamID
        settings["PROVISIONING_PROFILE_SPECIFIER"] = profile.uuid
        settings["PROVISIONING_PROFILE"] = profile.uuid
        settings["CODE_SIGN_IDENTITY"] = profile.certificateHash
        config["buildSettings"] = settings
        objects[configID] = config
        project["objects"] = objects
        return try PropertyListSerialization.data(fromPropertyList: project, format: .xml, options: 0)
    }

    static func applicationBundleID(
        containerPath: String, scheme: String, configuration: String,
        cancellation: BuildCancellationController
    ) throws -> String {
        let directory = URL(fileURLWithPath: containerPath, isDirectory: true)
        let container = try findXcodeContainer(in: directory)
        return try applicationBundleID(
            containerArguments: arguments(for: container), scheme: scheme,
            configuration: configuration, cancellation: cancellation
        )
    }

    private static func applicationBundleID(
        containerArguments: [String], scheme: String, configuration: String,
        cancellation: BuildCancellationController
    ) throws -> String {
        let result = try runXcodebuild(
            containerArguments + ["-scheme", scheme, "-configuration", configuration,
                                  "-destination", PackagePlatform.iOS.destination, "-showBuildSettings", "-json"],
            cancellation: cancellation, onOutput: { _ in }
        )
        guard !cancellation.isCancelled else { throw PackageError.cancelled }
        guard result.status == 0 else { throw PackageError.commandFailed(result.status, result.output) }
        return try manualSigningBundleID(from: result.output)
    }

    static func manualSigningBundleID(from output: String) throws -> String {
        guard let start = output.firstIndex(of: "["),
              let end = output.lastIndex(of: "]"),
              let entries = try JSONSerialization.jsonObject(with: Data(output[start...end].utf8)) as? [[String: Any]] else {
            throw PackageError.invalidInput("无法读取工程签名构建设置。")
        }
        let applications = entries.filter { entry in
            let settings = entry["buildSettings"] as? [String: String] ?? [:]
            return settings["PRODUCT_TYPE"] == "com.apple.product-type.application"
        }
        guard applications.count == 1,
              let settings = applications[0]["buildSettings"] as? [String: String],
              let bundleID = settings["PRODUCT_BUNDLE_IDENTIFIER"], !bundleID.isEmpty else {
            throw PackageError.invalidInput("无法确认唯一的 iOS App Bundle ID；手动签名需要为每个应用目标单独配置描述文件。")
        }
        let signedTargets = entries.filter { entry in
            let settings = entry["buildSettings"] as? [String: String] ?? [:]
            return settings["PRODUCT_TYPE"] == "com.apple.product-type.app-extension"
        }
        guard signedTargets.isEmpty else {
            throw PackageError.invalidInput("当前手动签名仅支持单个 App；含 Extension 的工程需要为各目标分别配置描述文件。")
        }
        return bundleID
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
        let profileUUID: String
    }

    static func validateArchivedSigning(
        selected: ManualSigningProfile,
        archivedTeamID: String,
        archivedProfileName: String,
        archivedProfileUUID: String
    ) throws {
        let selectedSummary = "所选：\(selected.name)（UUID: \(selected.uuid)），Team: \(selected.teamID)"
        let archivedSummary = "归档实际：\(archivedProfileName)（UUID: \(archivedProfileUUID)），Team: \(archivedTeamID)"
        if archivedTeamID != selected.teamID {
            throw PackageError.invalidInput("归档 Team 与所选描述文件的 Team 不一致。\n\(selectedSummary)\n\(archivedSummary)")
        }
        if archivedProfileUUID.caseInsensitiveCompare(selected.uuid) != .orderedSame {
            throw PackageError.invalidInput("归档描述文件与所选描述文件不一致。\n\(selectedSummary)\n\(archivedSummary)")
        }
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
              let profileUUID = profile["UUID"] as? String,
              let teamIdentifiers = profile["TeamIdentifier"] as? [String],
              let teamIdentifier = teamIdentifiers.first else {
            throw PackageError.invalidInput("无法读取归档内的 Provisioning Profile 签名信息。")
        }

        return SigningInfo(
            bundleIdentifier: bundleIdentifier,
            teamIdentifier: teamIdentifier,
            profileName: profileName,
            profileUUID: profileUUID
        )
    }

    private static func makeExportOptionsPlist(
        at url: URL,
        signingInfo: SigningInfo,
        manualProfile: ManualSigningProfile?
    ) throws {
        let options: [String: Any] = [
            "destination": "export",
            "method": manualProfile?.exportMethod ?? "debugging",
            "signingCertificate": manualProfile?.certificateHash ?? "Apple Development",
            "signingStyle": "manual",
            "teamID": manualProfile?.teamID ?? signingInfo.teamIdentifier,
            "provisioningProfiles": [
                signingInfo.bundleIdentifier: manualProfile?.uuid ?? signingInfo.profileName
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

    private static func findMainProject(in directoryURL: URL, workspaceURL: URL) throws -> URL? {
        guard workspaceURL.pathExtension.lowercased() == "xcworkspace" else { return nil }

        let projects = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter {
            $0.pathExtension.lowercased() == "xcodeproj"
                && $0.deletingPathExtension().lastPathComponent.lowercased() != "pods"
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        if let project = projects.first(where: {
            $0.deletingPathExtension().lastPathComponent == workspaceURL.deletingPathExtension().lastPathComponent
        }) {
            return project
        }
        if projects.count == 1 { return projects[0] }
        throw PackageError.invalidInput("无法确定主项目的 .xcodeproj，请选择只包含一个主工程的项目文件夹。")
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

    static func copyArchivedDSYMs(from archiveURL: URL, to artifactDirectoryURL: URL) throws {
        let fileManager = FileManager.default
        let sourceURL = archiveURL.appendingPathComponent("dSYMs", isDirectory: true)
        let symbols = (try? fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ))?.filter {
            $0.pathExtension.lowercased() == "dsym" &&
                ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        } ?? []
        guard !symbols.isEmpty else {
            throw PackageError.invalidInput("归档中没有找到 dSYM 文件，请确认应用目标支持生成调试符号。")
        }

        let destinationURL = artifactDirectoryURL.appendingPathComponent("dSYMs", isDirectory: true)
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        for symbol in symbols {
            try fileManager.copyItem(
                at: symbol,
                to: destinationURL.appendingPathComponent(symbol.lastPathComponent, isDirectory: true)
            )
        }
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

    static func saveXcodeArchive(
        from sourceURL: URL,
        for scheme: String,
        in archivesURL: URL,
        at date: Date = Date()
    ) throws -> URL {
        let fileManager = FileManager.default
        var destinationURL = try xcodeArchiveURL(for: scheme, in: archivesURL, at: date)
        while true {
            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                return destinationURL
            } catch let error as NSError where error.domain == NSCocoaErrorDomain &&
                error.code == CocoaError.fileWriteFileExists.rawValue {
                destinationURL = try xcodeArchiveURL(for: scheme, in: archivesURL, at: date)
            }
        }
    }

    static func xcodeArchiveURL(for scheme: String, in archivesURL: URL, at date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let dayURL = archivesURL.appendingPathComponent(formatter.string(from: date), isDirectory: true)
        try FileManager.default.createDirectory(at: dayURL, withIntermediateDirectories: true)

        formatter.dateFormat = "yyyy-M-d, H.mm"
        let name = "\(safeFileName(scheme)) \(formatter.string(from: date))"
        var suffix = 1
        while true {
            let fileName = suffix == 1 ? name : "\(name) \(suffix)"
            let candidate = dayURL.appendingPathComponent(fileName + ".xcarchive", isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
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
