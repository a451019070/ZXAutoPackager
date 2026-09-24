import AppKit
import Combine
import Foundation

private final class BuildLogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var content = ""

    func append(_ value: String) {
        lock.lock()
        content.append(value)
        lock.unlock()
    }

    func drain() -> String {
        lock.lock()
        defer { lock.unlock() }
        let value = content
        content.removeAll(keepingCapacity: true)
        return value
    }
}

private final class ScopedDirectoryAccess: @unchecked Sendable {
    let url: URL
    private let isAccessing: Bool

    init(url: URL) {
        self.url = url
        isAccessing = url.startAccessingSecurityScopedResource()
    }

    func stop() {
        if isAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

enum PackagePlatform: String, CaseIterable, Identifiable, Sendable {
    case iOS = "iOS"
    case macOS = "macOS"

    var id: String { rawValue }
    var destination: String { "generic/platform=\(rawValue)" }
    var artifactType: String { self == .iOS ? "IPA" : "ZIP" }
}

struct PackageRequest: Sendable {
    let platform: PackagePlatform
    let containerPath: String
    let scheme: String
    let configuration: String
    let versionNumber: String
    let buildNumber: Int
    let outputDirectory: String
}

struct PackageResult: Sendable {
    let artifactPath: String
    let fileSize: Int64
    let versionNumber: String
    let buildNumber: Int
    let configuration: String
    let log: String
}

struct PackageSummary: Sendable {
    let fileName: String
    let fileSize: String
    let version: String
    let buildNumber: Int
    let configuration: String
}

enum PackageError: LocalizedError {
    case invalidInput(String)
    case commandFailed(Int32, String)
    case productNotFound(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return message
        case .commandFailed(let code, let log):
            return "构建失败（退出码 \(code)）\n\(log)"
        case .productNotFound(let log):
            return "归档完成，但没有找到导出的 .ipa。\n\(log)"
        case .cancelled:
            return "打包已由用户停止。"
        }
    }
}

@MainActor
final class PackagerViewModel: ObservableObject {
    enum Configuration: String, CaseIterable, Identifiable {
        case debug = "Debug"
        case release = "Release"

        var id: String { rawValue }
    }

    @Published var containerPath = "" {
        didSet { defaults.set(containerPath, forKey: Keys.containerPath) }
    }
    @Published var scheme = "" {
        didSet { defaults.set(scheme, forKey: Keys.scheme) }
    }
    @Published var platform: PackagePlatform = .iOS {
        didSet {
            defaults.set(platform.rawValue, forKey: Keys.platform)
            if platform == .macOS {
                uploadToPgyer = false
                usePgyerBuildNumber = false
            }
        }
    }
    @Published var configuration: Configuration = .release {
        didSet { defaults.set(configuration.rawValue, forKey: Keys.configuration) }
    }
    @Published var versionNumber = "" {
        didSet { defaults.set(versionNumber, forKey: Keys.versionNumber) }
    }
    @Published var buildNumber = "" {
        didSet { defaults.set(buildNumber, forKey: Keys.buildNumber) }
    }
    @Published var outputDirectory = "" {
        didSet { defaults.set(outputDirectory, forKey: Keys.outputDirectory) }
    }
    @Published var uploadToPgyer = false {
        didSet { defaults.set(uploadToPgyer, forKey: Keys.uploadToPgyer) }
    }
    @Published var usePgyerBuildNumber = false {
        didSet { defaults.set(usePgyerBuildNumber, forKey: Keys.usePgyerBuildNumber) }
    }
    @Published var pgyerAPIKey = "" {
        didSet { defaults.set(pgyerAPIKey, forKey: Keys.pgyerAPIKey) }
    }
    @Published var pgyerAppKey = "" {
        didSet { defaults.set(pgyerAppKey, forKey: Keys.pgyerAppKey) }
    }
    @Published var updateDescription = ""
    @Published var sendToFeishu = false {
        didSet { defaults.set(sendToFeishu, forKey: Keys.sendToFeishu) }
    }
    @Published var feishuWebhook = "" {
        didSet { defaults.set(feishuWebhook, forKey: Keys.feishuWebhook) }
    }
    @Published var feishuImageKey = "" {
        didSet { defaults.set(feishuImageKey, forKey: Keys.feishuImageKey) }
    }
    @Published var useGitBranch = false {
        didSet { defaults.set(useGitBranch, forKey: Keys.useGitBranch) }
    }
    @Published var selectedBranch = "" {
        didSet { defaults.set(selectedBranch, forKey: Keys.selectedBranch) }
    }
    @Published var installPods = true {
        didSet { defaults.set(installPods, forKey: Keys.installPods) }
    }
    @Published var remoteBranches: [String] = []
    @Published var availableSchemes: [String] = []
    @Published var isLoadingSchemes = false
    @Published var isLoadingBranches = false
    @Published var isLoadingPgyerBuildNumber = false
    @Published var isPackaging = false
    @Published var elapsedSeconds = 0
    @Published var statusMessage = "请选择工程和导出目录"
    @Published var log = ""
    @Published var lastArtifactPath: String?
    @Published var packageSummary: PackageSummary?
    @Published var pgyerDownloadURL: String?
    @Published var isShowingQRCode = false

    private enum Keys {
        static let containerPath = "ZXAutoPackager.containerPath"
        static let scheme = "ZXAutoPackager.scheme"
        static let platform = "ZXAutoPackager.platform"
        static let configuration = "ZXAutoPackager.configuration"
        static let versionNumber = "ZXAutoPackager.versionNumber"
        static let buildNumber = "ZXAutoPackager.buildNumber"
        static let outputDirectory = "ZXAutoPackager.outputDirectory"
        static let projectBookmark = "ZXAutoPackager.projectBookmark"
        static let outputBookmark = "ZXAutoPackager.outputBookmark"
        static let uploadToPgyer = "ZXAutoPackager.uploadToPgyer"
        static let usePgyerBuildNumber = "ZXAutoPackager.usePgyerBuildNumber"
        static let pgyerAPIKey = "ZXAutoPackager.pgyerAPIKey"
        static let pgyerAppKey = "ZXAutoPackager.pgyerAppKey"
        static let sendToFeishu = "ZXAutoPackager.sendToFeishu"
        static let feishuWebhook = "ZXAutoPackager.feishuWebhook"
        static let feishuImageKey = "ZXAutoPackager.feishuImageKey"
        static let useGitBranch = "ZXAutoPackager.useGitBranch"
        static let selectedBranch = "ZXAutoPackager.selectedBranch"
        static let installPods = "ZXAutoPackager.installPods"
        static let lastSuccessfulBuild = "ZXAutoPackager.lastSuccessfulBuild"
    }

    private let defaults = UserDefaults.standard
    private let maximumLogLength = 300_000
    private var logRefreshTask: Task<Void, Never>?
    private var elapsedTimeTask: Task<Void, Never>?
    private var packageTask: Task<Void, Never>?
    private var cancellationController: BuildCancellationController?
    private var schemeLookupID = UUID()

    deinit {
        logRefreshTask?.cancel()
        elapsedTimeTask?.cancel()
        packageTask?.cancel()
        cancellationController?.cancel()
    }

    init() {
        containerPath = defaults.string(forKey: Keys.containerPath) ?? ""
        scheme = defaults.string(forKey: Keys.scheme) ?? ""
        platform = PackagePlatform(rawValue: defaults.string(forKey: Keys.platform) ?? "") ?? .iOS
        configuration = Configuration(
            rawValue: defaults.string(forKey: Keys.configuration) ?? ""
        ) ?? .release
        versionNumber = defaults.string(forKey: Keys.versionNumber) ?? ""
        outputDirectory = defaults.string(forKey: Keys.outputDirectory) ?? ""
        uploadToPgyer = platform == .iOS && defaults.bool(forKey: Keys.uploadToPgyer)
        usePgyerBuildNumber = false
        defaults.set(false, forKey: Keys.usePgyerBuildNumber)
        pgyerAPIKey = defaults.string(forKey: Keys.pgyerAPIKey) ?? ""
        pgyerAppKey = defaults.string(forKey: Keys.pgyerAppKey) ?? ""
        sendToFeishu = defaults.bool(forKey: Keys.sendToFeishu)
        feishuWebhook = defaults.string(forKey: Keys.feishuWebhook) ?? ""
        feishuImageKey = defaults.string(forKey: Keys.feishuImageKey) ?? ""
        defaults.removeObject(forKey: "ZXAutoPackager.feishuAppID")
        defaults.removeObject(forKey: "ZXAutoPackager.feishuAppSecret")
        defaults.removeObject(forKey: "ZXAutoPackager.updateDescription")
        useGitBranch = defaults.bool(forKey: Keys.useGitBranch)
        selectedBranch = defaults.string(forKey: Keys.selectedBranch) ?? ""
        installPods = defaults.object(forKey: Keys.installPods) == nil
            ? true
            : defaults.bool(forKey: Keys.installPods)

        buildNumber = defaults.string(forKey: Keys.buildNumber) ?? ""

        if !containerPath.isEmpty || !outputDirectory.isEmpty {
            statusMessage = "已恢复上次填写的打包配置"
        }
    }

    var canPackage: Bool {
        let trimmedVersion = versionNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBuild = buildNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionCanResolve = trimmedVersion.isEmpty || isValidVersionNumber
        let buildCanResolve = usePgyerBuildNumber || trimmedBuild.isEmpty || Int(trimmedBuild).map { $0 > 0 } == true

        return         !isPackaging &&
        !isLoadingSchemes &&
        !isLoadingPgyerBuildNumber &&
        !containerPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (availableSchemes.isEmpty || availableSchemes.contains(scheme)) &&
        versionCanResolve &&
        buildCanResolve &&
        (platform == .iOS || (!uploadToPgyer && !usePgyerBuildNumber)) &&
        !outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!(uploadToPgyer || usePgyerBuildNumber) || hasPgyerAPIKey) &&
        (!usePgyerBuildNumber || hasPgyerAppKey) &&
        (!useGitBranch || !selectedBranch.isEmpty) &&
        (!sendToFeishu || FeishuNotifier.validWebhook(feishuWebhook.trimmingCharacters(in: .whitespacesAndNewlines)) != nil)
    }

    var configurationHint: String {
        if containerPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请先选择项目文件夹" }
        if isLoadingSchemes { return "正在读取项目 Scheme…" }
        if scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请选择或填写 Scheme" }
        if !availableSchemes.isEmpty && !availableSchemes.contains(scheme) { return "请选择当前工程可用的 Scheme" }
        if outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请选择导出目录" }
        if platform == .macOS && (uploadToPgyer || usePgyerBuildNumber) { return "macOS 不支持蒲公英上传或 Build 号查询" }
        if !versionNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isValidVersionNumber {
            return "请在高级选项中检查版本号格式"
        }
        let trimmedBuild = buildNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if !usePgyerBuildNumber && !trimmedBuild.isEmpty && Int(trimmedBuild).map({ $0 > 0 }) != true {
            return "请在高级选项中填写有效的 Build 号"
        }
        if useGitBranch && selectedBranch.isEmpty { return "请在高级选项中选择远程分支" }
        if (uploadToPgyer || usePgyerBuildNumber) && !hasPgyerAPIKey { return "请填写蒲公英 API Key" }
        if usePgyerBuildNumber && !hasPgyerAppKey { return "请填写蒲公英 App Key" }
        if sendToFeishu && FeishuNotifier.validWebhook(feishuWebhook.trimmingCharacters(in: .whitespacesAndNewlines)) == nil { return "请填写有效的飞书机器人 Webhook" }
        if isLoadingPgyerBuildNumber { return "正在查询蒲公英 Build 号…" }
        return "配置已就绪，可以开始打包"
    }

    var canFetchPgyerBuildNumber: Bool {
        platform == .iOS &&
        !isPackaging &&
        !isLoadingPgyerBuildNumber &&
        isValidVersionNumber &&
        hasPgyerAPIKey &&
        hasPgyerAppKey
    }

    var elapsedTimeText: String {
        let minutes = elapsedSeconds / 60
        let seconds = elapsedSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private var isValidVersionNumber: Bool {
        let value = versionNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        return value.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression) != nil
    }

    private var hasPgyerAPIKey: Bool {
        !pgyerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasPgyerAppKey: Bool {
        !pgyerAppKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func fetchNextBuildNumberFromPgyer() {
        guard isValidVersionNumber else {
            statusMessage = "版本号格式不正确，例如：1.0 或 1.2.3"
            return
        }
        guard hasPgyerAPIKey, hasPgyerAppKey else {
            statusMessage = "请填写蒲公英 API Key 和 App Key"
            return
        }
        guard !isPackaging, !isLoadingPgyerBuildNumber else { return }

        isLoadingPgyerBuildNumber = true
        statusMessage = "正在查询蒲公英历史版本…"
        let apiKey = pgyerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let appKey = pgyerAppKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = versionNumber.trimmingCharacters(in: .whitespacesAndNewlines)

        Task {
            do {
                let nextBuild = try await PgyerUploader.nextBuildNumber(
                    apiKey: apiKey,
                    appKey: appKey,
                    version: version
                ) { _ in }
                self.buildNumber = String(nextBuild)
                self.isLoadingPgyerBuildNumber = false
                self.statusMessage = "蒲公英版本 \(version) 的下一 Build 号：\(nextBuild)"
            } catch is CancellationError {
                self.isLoadingPgyerBuildNumber = false
                self.statusMessage = "已取消查询蒲公英 Build 号"
            } catch {
                self.isLoadingPgyerBuildNumber = false
                self.statusMessage = "蒲公英 Build 号查询失败：\(error.localizedDescription)"
            }
        }
    }

    func refreshBranches(fetchRemote: Bool = true) {
        guard !containerPath.isEmpty, !isLoadingBranches, !isPackaging else { return }
        guard let projectAccess = restoreAccess(
            bookmarkKey: Keys.projectBookmark,
            fallbackPath: containerPath,
            directoryName: "项目目录"
        ) else {
            return
        }

        isLoadingBranches = true
        statusMessage = fetchRemote ? "正在刷新远程分支…" : "正在读取远程分支…"
        let projectPath = projectAccess.url.path

        Task.detached(priority: .userInitiated) {
            defer { projectAccess.stop() }
            do {
                let branches = try GitWorktreeManager.listRemoteBranches(
                    projectPath: projectPath,
                    fetchRemote: fetchRemote
                )
                await MainActor.run {
                    self.remoteBranches = branches
                    if !branches.contains(self.selectedBranch) {
                        self.selectedBranch = branches.first ?? ""
                    }
                    self.isLoadingBranches = false
                    self.statusMessage = "已读取 \(branches.count) 个远程分支"
                }
            } catch {
                await MainActor.run {
                    self.isLoadingBranches = false
                    self.statusMessage = "分支读取失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func refreshSchemes() {
        guard !containerPath.isEmpty, !isPackaging else { return }
        guard let projectAccess = restoreAccess(
            bookmarkKey: Keys.projectBookmark,
            fallbackPath: containerPath,
            directoryName: "项目目录"
        ) else { return }

        let lookupID = UUID()
        schemeLookupID = lookupID
        let projectPath = containerPath
        isLoadingSchemes = true
        statusMessage = "正在读取项目 Scheme…"
        Task.detached(priority: .userInitiated) {
            defer { projectAccess.stop() }
            do {
                let schemes = try XcodePackager.listSchemes(containerPath: projectAccess.url.path)
                await MainActor.run {
                    guard self.schemeLookupID == lookupID, self.containerPath == projectPath else { return }
                    self.availableSchemes = schemes
                    if !schemes.contains(self.scheme) {
                        self.scheme = schemes.count == 1 ? schemes[0] : ""
                    }
                    self.isLoadingSchemes = false
                    self.statusMessage = schemes.isEmpty
                        ? "当前工程没有可用的共享 Scheme，请在 Xcode 中检查 Scheme 配置"
                        : schemes.count == 1 ? "已选择 Scheme：\(schemes[0])" : "请选择要打包的 Scheme"
                }
            } catch {
                await MainActor.run {
                    guard self.schemeLookupID == lookupID, self.containerPath == projectPath else { return }
                    self.availableSchemes = []
                    self.isLoadingSchemes = false
                    self.statusMessage = "读取 Scheme 失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "选择 Xcode 项目文件夹"
        panel.message = "请选择包含 .xcworkspace 或 .xcodeproj 的项目根目录"
        panel.prompt = "选择项目文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = safePickerDirectory(preferredPath: containerPath)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveBookmark(for: url, key: Keys.projectBookmark)
        let projectChanged = containerPath != url.path
        containerPath = url.path
        if projectChanged {
            scheme = ""
            availableSchemes = []
            versionNumber = ""
            buildNumber = ""
            remoteBranches = []
            selectedBranch = ""
        }
        refreshSchemes()
        if useGitBranch {
            refreshBranches(fetchRemote: false)
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择导出目录"
        panel.prompt = "导出到这里"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = safePickerDirectory(preferredPath: outputDirectory)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveBookmark(for: url, key: Keys.outputBookmark)
        outputDirectory = url.path
        statusMessage = "导出目录已选择"
    }

    func startPackaging() {
        guard canPackage else {
            statusMessage = configurationHint
            return
        }

        guard let projectAccess = restoreAccess(
            bookmarkKey: Keys.projectBookmark,
            fallbackPath: containerPath,
            directoryName: "项目目录"
        ) else {
            return
        }
        guard let outputAccess = restoreAccess(
            bookmarkKey: Keys.outputBookmark,
            fallbackPath: outputDirectory,
            directoryName: "导出目录"
        ) else {
            projectAccess.stop()
            return
        }

        let scheme = scheme.trimmingCharacters(in: .whitespacesAndNewlines)
        let platform = platform
        let configuration = configuration.rawValue
        let enteredVersion = versionNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let enteredBuild = buildNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldUploadToPgyer = uploadToPgyer
        let shouldUsePgyerBuildNumber = usePgyerBuildNumber
        let shouldUseGitBranch = useGitBranch
        let branchToBuild = selectedBranch
        let shouldInstallPods = installPods
        let apiKey = pgyerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let appKey = pgyerAppKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let updateDescription = updateDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldSendToFeishu = sendToFeishu
        let webhook = feishuWebhook.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageKey = feishuImageKey.trimmingCharacters(in: .whitespacesAndNewlines)

        isPackaging = true
        elapsedSeconds = 0
        startElapsedTimer()
        lastArtifactPath = nil
        packageSummary = nil
        pgyerDownloadURL = nil
        log = ""
        statusMessage = enteredVersion.isEmpty || (!shouldUsePgyerBuildNumber && enteredBuild.isEmpty)
            ? "正在读取 Xcode 项目的版本信息…"
            : "正在准备打包…"

        let logBuffer = BuildLogBuffer()
        startLogRefresh(from: logBuffer)

        let cancellation = BuildCancellationController()
        cancellationController = cancellation
        packageTask = Task.detached(priority: .userInitiated) {
            var worktreeContext: GitWorktreeContext?
            defer {
                if let worktreeContext {
                    GitWorktreeManager.cleanup(worktreeContext)
                }
                projectAccess.stop()
                outputAccess.stop()
            }

            do {
                var effectiveProjectPath = projectAccess.url.path
                if shouldUseGitBranch {
                    let context = try GitWorktreeManager.prepare(
                        projectPath: effectiveProjectPath,
                        branch: branchToBuild,
                        installPods: shouldInstallPods,
                        cancellation: cancellation
                    ) { chunk in
                        logBuffer.append(chunk)
                    }
                    worktreeContext = context
                    effectiveProjectPath = context.projectDirectory.path
                }

                var resolvedVersion = enteredVersion
                var resolvedBuild = enteredBuild
                if resolvedVersion.isEmpty || (!shouldUsePgyerBuildNumber && resolvedBuild.isEmpty) {
                    logBuffer.append("\n===== 读取 Xcode 版本信息 =====\n")
                    let projectVersion = try XcodePackager.readBuildVersion(
                        containerPath: effectiveProjectPath,
                        scheme: scheme,
                        configuration: configuration,
                        platform: platform,
                        cancellation: cancellation
                    )
                    if resolvedVersion.isEmpty {
                        resolvedVersion = projectVersion.marketingVersion
                    }
                    if !shouldUsePgyerBuildNumber && resolvedBuild.isEmpty {
                        resolvedBuild = projectVersion.currentProjectVersion
                    }
                }

                guard !resolvedVersion.isEmpty,
                      resolvedVersion.range(
                        of: #"^\d+(\.\d+)*$"#,
                        options: .regularExpression
                      ) != nil else {
                    throw PackageError.invalidInput(
                        "Xcode 的 MARKETING_VERSION 格式不正确，例如应为 1.0 或 1.2.3。"
                    )
                }

                let build: Int
                if shouldUsePgyerBuildNumber {
                    await MainActor.run {
                        self.isLoadingPgyerBuildNumber = true
                        self.statusMessage = "正在从蒲公英获取下一 Build 号…"
                    }
                    build = try await PgyerUploader.nextBuildNumber(
                        apiKey: apiKey,
                        appKey: appKey,
                        version: resolvedVersion
                    ) { _ in }
                } else {
                    guard let value = Int(resolvedBuild), value > 0 else {
                        throw PackageError.invalidInput(
                            "Xcode 的 CURRENT_PROJECT_VERSION 必须是大于 0 的整数。"
                        )
                    }
                    build = value
                }

                await MainActor.run {
                    self.versionNumber = resolvedVersion
                    self.buildNumber = String(build)
                    self.isLoadingPgyerBuildNumber = false
                    self.statusMessage = "正在归档并导出 \(configuration) \(platform.artifactType)…"
                }

                let request = PackageRequest(
                    platform: platform,
                    containerPath: effectiveProjectPath,
                    scheme: scheme,
                    configuration: configuration,
                    versionNumber: resolvedVersion,
                    buildNumber: build,
                    outputDirectory: outputAccess.url.path
                )
                let packageResult = try XcodePackager.package(
                    request,
                    cancellation: cancellation
                ) { chunk in
                    logBuffer.append(chunk)
                }
                try Task.checkCancellation()
                guard !cancellation.isCancelled else { throw PackageError.cancelled }

                var uploadResult: PgyerUploadResult?
                if shouldUploadToPgyer {
                    let finalUpdateDescription = Self.makeUploadDescription(
                        userDescription: updateDescription,
                        packageResult: packageResult
                    )
                    logBuffer.append("\n===== 更新说明 =====\n\(finalUpdateDescription)\n")
                    let uploadRequest = PgyerUploadRequest(
                        apiKey: apiKey,
                        ipaPath: packageResult.artifactPath,
                        updateDescription: finalUpdateDescription
                    )
                    uploadResult = try await PgyerUploader.upload(uploadRequest) { chunk in
                        logBuffer.append(chunk)
                    }
                }

                var notificationError: String?
                if shouldSendToFeishu {
                    logBuffer.append("\n===== 飞书通知 =====\n")
                    do {
                        try await FeishuNotifier.send(
                            FeishuNotification(
                                scheme: scheme,
                                platform: platform,
                                result: packageResult,
                                downloadURL: uploadResult?.downloadURL,
                                updateDescription: updateDescription
                            ),
                            webhook: webhook,
                            imageKey: imageKey
                        ) { chunk in
                            logBuffer.append(chunk)
                        }
                    } catch {
                        notificationError = error.localizedDescription
                        logBuffer.append("飞书通知失败：\(error.localizedDescription)\n")
                    }
                }

                await MainActor.run {
                    self.finishLogRefresh(from: logBuffer)
                    self.stopElapsedTimer()
                    self.isPackaging = false
                    self.isLoadingPgyerBuildNumber = false
                    self.packageTask = nil
                    self.cancellationController = nil
                    self.lastArtifactPath = packageResult.artifactPath
                    self.packageSummary = PackageSummary(
                        fileName: URL(fileURLWithPath: packageResult.artifactPath).lastPathComponent,
                        fileSize: ByteCountFormatter.string(
                            fromByteCount: packageResult.fileSize,
                            countStyle: .file
                        ),
                        version: packageResult.versionNumber,
                        buildNumber: packageResult.buildNumber,
                        configuration: packageResult.configuration
                    )
                    self.pgyerDownloadURL = uploadResult?.downloadURL
                    if let uploadResult {
                        self.statusMessage = "上传成功：\(uploadResult.appName) \(uploadResult.version)"
                        self.showPgyerQRCode()
                    } else {
                        self.statusMessage = "打包成功：\(URL(fileURLWithPath: packageResult.artifactPath).lastPathComponent)"
                    }
                    if let notificationError {
                        self.statusMessage += "；飞书通知失败：\(notificationError)"
                    } else if shouldSendToFeishu {
                        self.statusMessage += "；飞书通知已发送"
                    }
                    self.defaults.set(build, forKey: Keys.lastSuccessfulBuild)
                    self.buildNumber = String(build + 1)
                    self.updateDescription = ""
                }
            } catch {
                await MainActor.run {
                    self.finishLogRefresh(from: logBuffer)
                    self.stopElapsedTimer()
                    self.isPackaging = false
                    self.isLoadingPgyerBuildNumber = false
                    self.packageTask = nil
                    self.cancellationController = nil
                    if error is CancellationError || cancellation.isCancelled {
                        self.appendLog("\n===== 已停止打包 =====\n")
                        self.statusMessage = "打包已停止"
                    } else {
                        let summary = self.errorSummary(error)
                        self.appendLog("\n\n===== 打包失败 =====\n\(summary)\n")
                        self.statusMessage = summary
                    }
                }
            }
        }
    }

    func stopPackaging() {
        guard isPackaging else { return }
        statusMessage = "正在停止打包…"
        appendLog("\n正在停止当前任务…\n")
        cancellationController?.cancel()
        packageTask?.cancel()
    }

    private func startElapsedTimer() {
        elapsedTimeTask?.cancel()
        elapsedTimeTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.elapsedSeconds += 1
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimeTask?.cancel()
        elapsedTimeTask = nil
    }

    private func startLogRefresh(from buffer: BuildLogBuffer) {
        logRefreshTask?.cancel()
        logRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                let chunk = buffer.drain()
                if !chunk.isEmpty {
                    self.appendLog(chunk)
                }
            }
        }
    }

    private func finishLogRefresh(from buffer: BuildLogBuffer) {
        logRefreshTask?.cancel()
        logRefreshTask = nil
        let remainingLog = buffer.drain()
        if !remainingLog.isEmpty {
            appendLog(remainingLog)
        }
    }

    private func appendLog(_ value: String) {
        log.append(value)
        guard log.count > maximumLogLength else { return }
        log = "===== 较早日志已省略 =====\n" + String(log.suffix(maximumLogLength))
    }

    nonisolated private static func makeUploadDescription(
        userDescription: String,
        packageResult: PackageResult,
        uploadedAt: Date = Date()
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let environmentUser = ProcessInfo.processInfo.environment["USER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let systemUser = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let user = environmentUser.isEmpty ? systemUser : environmentUser
        let fullName = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        let uploader = fullName.isEmpty ? user : fullName

        var sections: [String] = []
        let description = userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty {
            sections.append(description)
        }

        sections.append("""
        上传人：\(uploader)
        上传时间：\(formatter.string(from: uploadedAt))
        Version：\(packageResult.versionNumber)
        Build：\(packageResult.buildNumber)
        User：\(user)
        构建环境：\(packageResult.configuration)
        """)
        return sections.joined(separator: "\n\n")
    }

    private func errorSummary(_ error: Error) -> String {
        if case PackageError.commandFailed(let code, _) = error {
            return "构建命令退出码：\(code)。详细错误请查看上方日志末尾。"
        }
        if case PackageError.productNotFound = error {
            return "归档完成，但没有找到导出的 IPA。"
        }
        return error.localizedDescription
    }

    private func safePickerDirectory(preferredPath: String) -> URL {
        let homeURL = FileManager.default.homeDirectoryForCurrentUser
        guard !preferredPath.isEmpty else { return homeURL }

        let preferredURL = URL(fileURLWithPath: preferredPath, isDirectory: true).standardizedFileURL
        return isInsideDesktop(preferredURL) ? homeURL : preferredURL
    }

    private func isInsideDesktop(_ url: URL) -> Bool {
        let desktopURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
            .standardizedFileURL
        let path = url.standardizedFileURL.path
        return path == desktopURL.path || path.hasPrefix(desktopURL.path + "/")
    }

    private func saveBookmark(for url: URL, key: String) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: key)
        } catch {
            statusMessage = "无法保存目录授权：\(error.localizedDescription)"
        }
    }

    private func restoreAccess(
        bookmarkKey: String,
        fallbackPath: String,
        directoryName: String
    ) -> ScopedDirectoryAccess? {
        let trimmedPath = fallbackPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            statusMessage = "请重新选择\(directoryName)"
            return nil
        }

        let fallbackURL = URL(fileURLWithPath: trimmedPath, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        let fallbackExists = FileManager.default.fileExists(
            atPath: fallbackURL.path,
            isDirectory: &isDirectory
        ) && isDirectory.boolValue

        if let data = defaults.data(forKey: bookmarkKey) {
            do {
                var isStale = false
                let bookmarkedURL = try URL(
                    resolvingBookmarkData: data,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                ).standardizedFileURL

                if bookmarkedURL.path == fallbackURL.path {
                    if isStale {
                        saveBookmark(for: bookmarkedURL, key: bookmarkKey)
                    }
                    return ScopedDirectoryAccess(url: bookmarkedURL)
                }

                defaults.removeObject(forKey: bookmarkKey)
            } catch {
                defaults.removeObject(forKey: bookmarkKey)
            }
        }

        guard fallbackExists else {
            statusMessage = "\(directoryName)不存在或无法访问，请重新选择：\(trimmedPath)"
            return nil
        }

        saveBookmark(for: fallbackURL, key: bookmarkKey)
        return ScopedDirectoryAccess(url: fallbackURL)
    }

    func showPgyerQRCode() {
        guard pgyerDownloadURL != nil else { return }
        isShowingQRCode = true
    }

    func openPgyerDownloadPage() {
        guard let pgyerDownloadURL, let url = URL(string: pgyerDownloadURL) else { return }
        NSWorkspace.shared.open(url)
    }

    func revealArtifact() {
        guard let lastArtifactPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lastArtifactPath)])
    }
}
