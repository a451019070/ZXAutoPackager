import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

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
    let signingProfileUUID: String?
    let isTemporaryProject: Bool
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
        didSet {
            defaults.set(containerPath, forKey: Keys.containerPath)
            if containerPath != oldValue { discardPreparedWorktree() }
        }
    }
    @Published var scheme = "" {
        didSet { defaults.set(scheme, forKey: Keys.scheme) }
    }
    @Published var platform: PackagePlatform = .iOS {
        didSet {
            guard !isRestoringProjectSwitches else { return }
            saveProjectPlatform()
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
        didSet {
            defaults.set(versionNumber, forKey: Keys.versionNumber)
            if !isRestoringProjectSwitches && usePgyerBuildNumber && versionNumber != oldValue {
                buildNumber = ""
                schedulePgyerBuildLookup()
            }
        }
    }
    @Published var buildNumber = "" {
        didSet { defaults.set(buildNumber, forKey: Keys.buildNumber) }
    }
    @Published private(set) var outputDirectory = ""
    @Published private(set) var projectDirectoryHistory: [String] = []
    @Published private(set) var outputDirectoryHistory: [String] = []
    @Published var uploadToPgyer = false {
        didSet {
            if !uploadToPgyer && usePgyerBuildNumber && !isRestoringProjectSwitches {
                usePgyerBuildNumber = false
            }
            saveProjectSwitches()
        }
    }
    @Published var usePgyerBuildNumber = false {
        didSet {
            saveProjectSwitches()
            guard !isRestoringProjectSwitches else { return }
            if !usePgyerBuildNumber && oldValue {
                pgyerLookupTask?.cancel()
                pgyerLookupID = UUID()
                isLoadingPgyerBuildNumber = false
                refreshXcodeBuildNumber()
            } else if usePgyerBuildNumber && !oldValue {
                hasManualBuildOverride = false
                buildNumber = ""
                if versionNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    refreshXcodeBuildNumber()
                } else {
                    fetchNextBuildNumberFromPgyer()
                }
            }
        }
    }
    @Published var pgyerAPIKey = "" {
        didSet {
            defaults.set(pgyerAPIKey, forKey: Keys.pgyerAPIKey)
            if usePgyerBuildNumber && pgyerAPIKey != oldValue {
                buildNumber = ""
                schedulePgyerBuildLookup()
            }
        }
    }
    @Published var pgyerAppKey = "" {
        didSet {
            defaults.set(pgyerAppKey, forKey: Keys.pgyerAppKey)
            if usePgyerBuildNumber && pgyerAppKey != oldValue {
                buildNumber = ""
                schedulePgyerBuildLookup()
            }
        }
    }
    @Published var updateDescription = ""
    @Published var sendToFeishu = false {
        didSet { saveProjectSwitches() }
    }
    @Published var feishuWebhook = "" {
        didSet { defaults.set(feishuWebhook, forKey: Keys.feishuWebhook) }
    }
    @Published var feishuImageKey = "" {
        didSet { defaults.set(feishuImageKey, forKey: Keys.feishuImageKey) }
    }
    @Published var useGitBranch = false {
        didSet {
            saveProjectSwitches()
            if useGitBranch != oldValue { discardPreparedWorktree() }
        }
    }
    @Published var selectedBranch = "" {
        didSet {
            defaults.set(selectedBranch, forKey: Keys.selectedBranch)
            if selectedBranch != oldValue { discardPreparedWorktree() }
            if mergeBranches.contains(selectedBranch) {
                mergeBranches.removeAll { $0 == selectedBranch }
            }
        }
    }
    @Published var mergeBranches: [String] = [] {
        didSet {
            if mergeBranches != oldValue { discardPreparedWorktree() }
        }
    }
    @Published var installPods = true {
        didSet {
            saveProjectSwitches()
            if installPods != oldValue { discardPreparedWorktree() }
        }
    }
    @Published var provisioningProfileName: String?
    @Published var signingProfileUUID: String? {
        didSet { defaults.set(signingProfileUUID, forKey: Keys.signingProfileUUID) }
    }
    @Published var signingImportMessage: String?
    @Published var installedSigningProfiles: [ManualSigningProfile] = []
    @Published var signingProfileBundleID: String?
    @Published var signingProfilesMessage: String?
    @Published var isLoadingSigningProfiles = false
    @Published var remoteBranches: [String] = []
    @Published var availableSchemes: [String] = []
    @Published var isLoadingSchemes = false
    @Published var isLoadingBranches = false
    @Published var isLoadingPgyerBuildNumber = false
    @Published var isPackaging = false
    @Published private(set) var isPreparing = false
    @Published private(set) var hasPreparedWorktree = false
    @Published private(set) var mergeConflictFiles: [String] = []
    @Published private(set) var mergeConflictBranch: String?
    @Published var elapsedSeconds = 0
    @Published var statusMessage = "请选择工程和导出目录"
    @Published var log = ""
    @Published var lastArtifactPath: String?
    @Published var packageSummary: PackageSummary?
    @Published var pgyerDownloadURL: String?
    @Published var isShowingQRCode = false
    @Published private(set) var packageHistory: [PackageHistoryRecord] = []
    @Published private(set) var historyError: String?

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
        static let projectDirectoryHistory = "ZXAutoPackager.projectDirectoryHistory"
        static let outputDirectoryHistory = "ZXAutoPackager.outputDirectoryHistory"
        static let projectBookmarkHistory = "ZXAutoPackager.projectBookmarkHistory"
        static let outputBookmarkHistory = "ZXAutoPackager.outputBookmarkHistory"
        static let uploadToPgyer = "ZXAutoPackager.uploadToPgyer"
        static let usePgyerBuildNumber = "ZXAutoPackager.usePgyerBuildNumber"
        static let pgyerAPIKey = "ZXAutoPackager.pgyerAPIKey"
        static let pgyerAppKey = "ZXAutoPackager.pgyerAppKey"
        static let sendToFeishu = "ZXAutoPackager.sendToFeishu"
        static let feishuWebhook = "ZXAutoPackager.feishuWebhook"
        static let feishuImageKey = "ZXAutoPackager.feishuImageKey"
        static let useGitBranch = "ZXAutoPackager.useGitBranch"
        static let selectedBranch = "ZXAutoPackager.selectedBranch"
        static let mergeBranches = "ZXAutoPackager.mergeBranches"
        static let mergeBranch = "ZXAutoPackager.mergeBranch"
        static let installPods = "ZXAutoPackager.installPods"
        static let signingProfileUUID = "ZXAutoPackager.signingProfileUUID"
        static let lastSuccessfulBuild = "ZXAutoPackager.lastSuccessfulBuild"
        static let projectSwitches = "ZXAutoPackager.projectSwitches"
        static let projectOutputDirectories = "ZXAutoPackager.projectOutputDirectories"
        static let projectPlatforms = "ZXAutoPackager.projectPlatforms"
    }

    private struct ProjectSwitches: Codable {
        var useGitBranch: Bool
        var sendToFeishu: Bool
        var uploadToPgyer: Bool
        var usePgyerBuildNumber: Bool
        var installPods: Bool

        private enum CodingKeys: String, CodingKey {
            case useGitBranch, sendToFeishu, uploadToPgyer, usePgyerBuildNumber, installPods
        }

        init(useGitBranch: Bool, sendToFeishu: Bool, uploadToPgyer: Bool,
             usePgyerBuildNumber: Bool, installPods: Bool) {
            self.useGitBranch = useGitBranch
            self.sendToFeishu = sendToFeishu
            self.uploadToPgyer = uploadToPgyer
            self.usePgyerBuildNumber = usePgyerBuildNumber
            self.installPods = installPods
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            useGitBranch = try values.decode(Bool.self, forKey: .useGitBranch)
            sendToFeishu = try values.decode(Bool.self, forKey: .sendToFeishu)
            uploadToPgyer = try values.decode(Bool.self, forKey: .uploadToPgyer)
            usePgyerBuildNumber = try values.decode(Bool.self, forKey: .usePgyerBuildNumber)
            installPods = try values.decodeIfPresent(Bool.self, forKey: .installPods) ?? true
        }

        static let disabled = ProjectSwitches(useGitBranch: false, sendToFeishu: false,
                                              uploadToPgyer: false, usePgyerBuildNumber: false,
                                              installPods: true)
    }

    private let defaults = UserDefaults.standard
    private var isRestoringProjectSwitches = false
    private let historyStore = PackageHistoryStore()
    private let maximumLogLength = 300_000
    private var logRefreshTask: Task<Void, Never>?
    private var elapsedTimeTask: Task<Void, Never>?
    private var packageTask: Task<Void, Never>?
    private var preparationTask: Task<Void, Never>?
    private var preparedWorktree: GitWorktreeContext?
    private var pausedMerge: GitMergeConflict?
    private var preparedConfiguration: PreparationConfiguration?

    private struct PreparationConfiguration: Equatable {
        let projectPath: String
        let branch: String
        let mergeBranches: [String]
        let installPods: Bool
    }

    private var currentPreparationConfiguration: PreparationConfiguration {
        PreparationConfiguration(projectPath: containerPath, branch: selectedBranch,
                                 mergeBranches: mergeBranches, installPods: installPods)
    }
    private var cancellationController: BuildCancellationController?
    private var schemeLookupID = UUID()
    private var buildLookupID = UUID()
    private var pgyerLookupID = UUID()
    private var pgyerLookupTask: Task<Void, Never>?
    private var hasManualVersionOverride = false
    private var hasManualBuildOverride = false
    private var signingLookupID = UUID()

    deinit {
        logRefreshTask?.cancel()
        elapsedTimeTask?.cancel()
        packageTask?.cancel()
        preparationTask?.cancel()
        pgyerLookupTask?.cancel()
        cancellationController?.cancel()
        if let preparedWorktree { GitWorktreeManager.cleanup(preparedWorktree) }

    }

    init() {
        do {
            packageHistory = try historyStore.load()
        } catch {
            historyError = "读取打包历史失败：\(error.localizedDescription)"
        }
        containerPath = defaults.string(forKey: Keys.containerPath) ?? ""
        scheme = defaults.string(forKey: Keys.scheme) ?? ""
        migrateLegacyProjectPlatform()
        restoreProjectPlatform(for: containerPath)
        configuration = Configuration(
            rawValue: defaults.string(forKey: Keys.configuration) ?? ""
        ) ?? .release
        versionNumber = ""
        projectDirectoryHistory = defaults.stringArray(forKey: Keys.projectDirectoryHistory) ?? []
        outputDirectoryHistory = defaults.stringArray(forKey: Keys.outputDirectoryHistory) ?? []
        migrateDirectoryHistory(path: containerPath, bookmarkKey: Keys.projectBookmark,
                                bookmarkHistoryKey: Keys.projectBookmarkHistory, isProject: true)
        let legacyOutputDirectory = defaults.string(forKey: Keys.outputDirectory) ?? ""
        migrateDirectoryHistory(path: legacyOutputDirectory, bookmarkKey: Keys.outputBookmark,
                                bookmarkHistoryKey: Keys.outputBookmarkHistory, isProject: false)
        migrateLegacyOutputDirectory(legacyOutputDirectory)
        restoreOutputDirectory(for: containerPath)
        pgyerAPIKey = defaults.string(forKey: Keys.pgyerAPIKey) ?? ""
        pgyerAppKey = defaults.string(forKey: Keys.pgyerAppKey) ?? ""
        feishuWebhook = defaults.string(forKey: Keys.feishuWebhook) ?? ""
        feishuImageKey = defaults.string(forKey: Keys.feishuImageKey) ?? ""
        defaults.removeObject(forKey: "ZXAutoPackager.feishuAppID")
        defaults.removeObject(forKey: "ZXAutoPackager.feishuAppSecret")
        defaults.removeObject(forKey: "ZXAutoPackager.updateDescription")
        migrateLegacyProjectSwitches()
        restoreProjectSwitches(for: containerPath)
        selectedBranch = defaults.string(forKey: Keys.selectedBranch) ?? ""
        defaults.removeObject(forKey: Keys.mergeBranches)
        defaults.removeObject(forKey: Keys.mergeBranch)

        buildNumber = ""
        signingProfileUUID = defaults.string(forKey: Keys.signingProfileUUID)
        if let signingProfileUUID {
            do {
                provisioningProfileName = try ManualSigningProfile.load(uuid: signingProfileUUID).name
            } catch {
                signingImportMessage = error.localizedDescription
            }
        }

        if !containerPath.isEmpty || !outputDirectory.isEmpty {
            statusMessage = "已恢复上次填写的打包配置"
        }
    }

    private func projectSwitchKey(for path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func migrateLegacyProjectPlatform() {
        guard let legacy = defaults.string(forKey: Keys.platform) else { return }
        if !containerPath.isEmpty {
            var platforms = defaults.dictionary(forKey: Keys.projectPlatforms) as? [String: String] ?? [:]
            let project = projectSwitchKey(for: containerPath)
            if platforms[project] == nil {
                platforms[project] = legacy
                defaults.set(platforms, forKey: Keys.projectPlatforms)
            }
        }
        defaults.removeObject(forKey: Keys.platform)
    }

    private func saveProjectPlatform() {
        guard !containerPath.isEmpty else { return }
        var platforms = defaults.dictionary(forKey: Keys.projectPlatforms) as? [String: String] ?? [:]
        platforms[projectSwitchKey(for: containerPath)] = platform.rawValue
        defaults.set(platforms, forKey: Keys.projectPlatforms)
    }

    private func restoreProjectPlatform(for path: String) {
        let platforms = defaults.dictionary(forKey: Keys.projectPlatforms) as? [String: String] ?? [:]
        let saved = path.isEmpty ? nil : platforms[projectSwitchKey(for: path)]
        isRestoringProjectSwitches = true
        platform = PackagePlatform(rawValue: saved ?? "") ?? .iOS
        isRestoringProjectSwitches = false
    }

    private func migrateLegacyOutputDirectory(_ path: String) {
        guard !containerPath.isEmpty, !path.isEmpty else {
            defaults.removeObject(forKey: Keys.outputDirectory)
            return
        }
        var directories = defaults.dictionary(forKey: Keys.projectOutputDirectories) as? [String: String] ?? [:]
        let project = projectSwitchKey(for: containerPath)
        if directories[project] == nil {
            directories[project] = path
            defaults.set(directories, forKey: Keys.projectOutputDirectories)
        }
        defaults.removeObject(forKey: Keys.outputDirectory)
    }

    private func restoreOutputDirectory(for path: String) {
        let directories = defaults.dictionary(forKey: Keys.projectOutputDirectories) as? [String: String] ?? [:]
        outputDirectory = path.isEmpty ? "" : directories[projectSwitchKey(for: path)] ?? ""
        if !outputDirectory.isEmpty {
            restoreHistoricalBookmark(for: outputDirectory, isProject: false)
        } else {
            defaults.removeObject(forKey: Keys.outputBookmark)
        }
    }

    private func setOutputDirectory(_ path: String) {
        outputDirectory = path
        guard !containerPath.isEmpty else { return }
        var directories = defaults.dictionary(forKey: Keys.projectOutputDirectories) as? [String: String] ?? [:]
        directories[projectSwitchKey(for: containerPath)] = path
        defaults.set(directories, forKey: Keys.projectOutputDirectories)
    }

    private func loadProjectSwitches() -> [String: ProjectSwitches] {
        guard let data = defaults.data(forKey: Keys.projectSwitches) else { return [:] }
        return (try? JSONDecoder().decode([String: ProjectSwitches].self, from: data)) ?? [:]
    }

    private func saveProjectSwitches() {
        guard !isRestoringProjectSwitches, !containerPath.isEmpty else { return }
        var records = loadProjectSwitches()
        records[projectSwitchKey(for: containerPath)] = ProjectSwitches(
            useGitBranch: useGitBranch, sendToFeishu: sendToFeishu,
            uploadToPgyer: uploadToPgyer, usePgyerBuildNumber: usePgyerBuildNumber,
            installPods: installPods
        )
        if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: Keys.projectSwitches)
        }
    }

    private func restoreProjectSwitches(for path: String) {
        let switches = path.isEmpty ? .disabled :
            loadProjectSwitches()[projectSwitchKey(for: path)] ?? .disabled
        isRestoringProjectSwitches = true
        useGitBranch = switches.useGitBranch
        sendToFeishu = switches.sendToFeishu
        uploadToPgyer = platform == .iOS && switches.uploadToPgyer
        usePgyerBuildNumber = uploadToPgyer && switches.usePgyerBuildNumber
        installPods = switches.installPods
        isRestoringProjectSwitches = false
    }

    private func migrateLegacyProjectSwitches() {
        let oldKeys = [Keys.useGitBranch, Keys.sendToFeishu,
                       Keys.uploadToPgyer, Keys.usePgyerBuildNumber, Keys.installPods]
        guard oldKeys.contains(where: { defaults.object(forKey: $0) != nil }) else { return }
        if !containerPath.isEmpty {
            let key = projectSwitchKey(for: containerPath)
            var records = loadProjectSwitches()
            if records[key] == nil {
                records[key] = ProjectSwitches(
                    useGitBranch: defaults.bool(forKey: Keys.useGitBranch),
                    sendToFeishu: defaults.bool(forKey: Keys.sendToFeishu),
                    uploadToPgyer: defaults.bool(forKey: Keys.uploadToPgyer),
                    usePgyerBuildNumber: defaults.bool(forKey: Keys.usePgyerBuildNumber),
                    installPods: defaults.object(forKey: Keys.installPods) == nil
                        ? true : defaults.bool(forKey: Keys.installPods)
                )
                if let data = try? JSONEncoder().encode(records) {
                    defaults.set(data, forKey: Keys.projectSwitches)
                }
            }
        }
        oldKeys.forEach { defaults.removeObject(forKey: $0) }
    }

    var canPrepareBranches: Bool {
        useGitBranch && !mergeBranches.isEmpty && !isPreparing && !isPackaging && !isLoadingBranches &&
        !containerPath.isEmpty && !selectedBranch.isEmpty &&
        remoteBranches.contains(selectedBranch) &&
        mergeBranches.allSatisfy { remoteBranches.contains($0) }
    }

    private var preparedWorktreeIsCurrent: Bool {
        guard let preparedWorktree, preparedConfiguration == currentPreparationConfiguration else { return false }
        return FileManager.default.fileExists(atPath: preparedWorktree.projectDirectory.path)
    }

    private func discardPreparedWorktree() {
        guard !isPackaging else { return }
        if isPreparing {
            cancellationController?.cancel()
            preparationTask?.cancel()
            return
        }
        if pausedMerge != nil {
            statusMessage = "冲突现场仍保留在临时 Worktree；请先继续合并或点击放弃并清理"
            return
        }
        if let preparedWorktree {
            self.preparedWorktree = nil
            preparedConfiguration = nil
            hasPreparedWorktree = false
            Task.detached(priority: .utility) {
                GitWorktreeManager.cleanup(preparedWorktree)
            }
            statusMessage = "分支配置已变化，请重新准备并合并"
        }
    }

    func prepareBranches() {
        guard pausedMerge == nil, canPrepareBranches else { return }
        discardPreparedWorktree()
        guard let projectAccess = restoreAccess(
            bookmarkKey: Keys.projectBookmark,
            fallbackPath: containerPath,
            directoryName: "项目目录"
        ) else { return }

        let configuration = currentPreparationConfiguration
        let cancellation = BuildCancellationController()
        cancellationController = cancellation
        isPreparing = true
        hasPreparedWorktree = false
        statusMessage = "正在准备并合并分支…"
        log = ""
        let logBuffer = BuildLogBuffer()
        startLogRefresh(from: logBuffer)
        preparationTask = Task.detached(priority: .userInitiated) {
            defer { projectAccess.stop() }
            do {
                let context = try GitWorktreeManager.prepare(
                    projectPath: projectAccess.url.path,
                    branch: configuration.branch,
                    mergeBranches: configuration.mergeBranches,
                    installPods: configuration.installPods,
                    cancellation: cancellation
                ) { chunk in logBuffer.append(chunk) }
                let accepted = await MainActor.run {
                    let accepted = !cancellation.isCancelled &&
                        self.currentPreparationConfiguration == configuration
                    if accepted {
                        self.preparedWorktree = context
                        self.preparedConfiguration = configuration
                        self.hasPreparedWorktree = true
                        self.finishLogRefresh(from: logBuffer)
                        self.statusMessage = "分支已准备并合并完成，可以开始打包"
                    } else {
                        self.finishLogRefresh(from: logBuffer)
                        self.statusMessage = "准备已取消或分支配置已变化，请重新准备"
                    }
                    self.isPreparing = false
                    self.preparationTask = nil
                    self.cancellationController = nil
                    return accepted
                }
                if !accepted { GitWorktreeManager.cleanup(context) }
            } catch let conflict as GitMergeConflict {
                let accepted = await MainActor.run {
                    let accepted = !cancellation.isCancelled && self.currentPreparationConfiguration == configuration
                    self.finishLogRefresh(from: logBuffer)
                    self.isPreparing = false
                    self.preparationTask = nil
                    self.cancellationController = nil
                    if accepted {
                        self.pausedMerge = conflict
                        self.preparedConfiguration = configuration
                        self.mergeConflictBranch = conflict.branch
                        self.mergeConflictFiles = conflict.files
                        self.appendLog("\n===== 合并冲突：origin/\(conflict.branch) =====\n临时 Worktree：\(conflict.context.worktreeRoot.path)\n\(conflict.output)\n")
                        self.statusMessage = "合并冲突已暂停，请在临时 Worktree 中解决后检查并继续"
                    }
                    return accepted
                }
                if !accepted { GitWorktreeManager.cleanup(conflict.context) }
            } catch {
                await MainActor.run {
                    self.finishLogRefresh(from: logBuffer)
                    self.isPreparing = false
                    self.preparationTask = nil
                    self.cancellationController = nil
                    if error is CancellationError || cancellation.isCancelled {
                        self.statusMessage = "准备已停止"
                    } else {
                        self.appendLog("\n===== 准备失败 =====\n\(error.localizedDescription)\n")
                        self.statusMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    func openConflictWorktree() {
        guard let pausedMerge else { return }
        NSWorkspace.shared.open(pausedMerge.context.worktreeRoot)
    }

    func discardMergeConflict() {
        guard !isPreparing, !isPackaging, let pausedMerge else { return }
        self.pausedMerge = nil
        self.preparedConfiguration = nil
        mergeConflictBranch = nil
        mergeConflictFiles = []
        statusMessage = "已放弃冲突合并，正在清理临时 Worktree"
        Task.detached(priority: .utility) { GitWorktreeManager.cleanup(pausedMerge.context) }
    }

    func continueMerge() {
        guard !isPreparing, !isPackaging, let conflict = pausedMerge,
              preparedConfiguration == currentPreparationConfiguration else { return }
        let configuration = currentPreparationConfiguration
        let cancellation = BuildCancellationController()
        cancellationController = cancellation
        isPreparing = true
        statusMessage = "正在检查冲突并继续合并…"
        let logBuffer = BuildLogBuffer()
        startLogRefresh(from: logBuffer)
        preparationTask = Task.detached(priority: .userInitiated) {
            do {
                let context = try GitWorktreeManager.continueMerge(
                    conflict: conflict,
                    remainingBranches: Array(configuration.mergeBranches.dropFirst(conflict.nextIndex)),
                    installPods: configuration.installPods, cancellation: cancellation
                ) { chunk in logBuffer.append(chunk) }
                await MainActor.run {
                    self.finishLogRefresh(from: logBuffer)
                    self.pausedMerge = nil
                    self.mergeConflictBranch = nil
                    self.mergeConflictFiles = []
                    self.preparedWorktree = context
                    self.hasPreparedWorktree = true
                    self.isPreparing = false
                    self.preparationTask = nil
                    self.cancellationController = nil
                    self.statusMessage = "冲突已解决，分支已合并完成，可以开始打包"
                }
            } catch let nextConflict as GitMergeConflict {
                await MainActor.run {
                    self.finishLogRefresh(from: logBuffer)
                    self.pausedMerge = nextConflict
                    self.mergeConflictBranch = nextConflict.branch
                    self.mergeConflictFiles = nextConflict.files
                    self.isPreparing = false
                    self.preparationTask = nil
                    self.cancellationController = nil
                    self.appendLog("\n===== 合并冲突：origin/\(nextConflict.branch) =====\n临时 Worktree：\(nextConflict.context.worktreeRoot.path)\n\(nextConflict.output)\n")
                    self.statusMessage = "后续分支再次冲突，请解决后继续"
                }
            } catch {
                await MainActor.run {
                    self.finishLogRefresh(from: logBuffer)
                    self.isPreparing = false
                    self.preparationTask = nil
                    self.cancellationController = nil
                    if let gitError = error as? GitPreparationError,
                       case .unresolvedConflicts(let files) = gitError {
                        self.mergeConflictFiles = files
                    }
                    self.statusMessage = error.localizedDescription
                    self.appendLog("\n===== 检查未通过 =====\n\(error.localizedDescription)\n")
                }
            }
        }
    }

    func stopPreparing() {
        guard isPreparing else { return }
        guard pausedMerge == nil else {
            statusMessage = "正在完成当前合并步骤，请稍候再操作"
            return
        }
        statusMessage = "正在停止准备…"
        cancellationController?.cancel()
        preparationTask?.cancel()
    }

    var canPackage: Bool {
        let trimmedVersion = versionNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let versionCanResolve = trimmedVersion.isEmpty || isValidVersionNumber
        let trimmedBuild = buildNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        let buildCanResolve = usePgyerBuildNumber || trimmedBuild.isEmpty || Int(trimmedBuild).map { $0 > 0 } == true

        return         !isPackaging &&
        !isPreparing &&
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
        pausedMerge == nil &&
        (!useGitBranch || (!selectedBranch.isEmpty && (mergeBranches.isEmpty || preparedWorktreeIsCurrent))) &&
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
            return "请检查版本号格式"
        }
        let trimmedBuild = buildNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if !usePgyerBuildNumber && !trimmedBuild.isEmpty && Int(trimmedBuild).map({ $0 > 0 }) != true {
            return "请填写有效的 Build 号"
        }
        if pausedMerge != nil { return "请先解决冲突并继续合并，或放弃并清理" }
        if useGitBranch && selectedBranch.isEmpty { return "请在高级选项中选择远程分支" }
        if useGitBranch && !mergeBranches.isEmpty && !preparedWorktreeIsCurrent {
            return "已选择合并分支，请先准备并合并后再打包"
        }
        if (uploadToPgyer || usePgyerBuildNumber) && !hasPgyerAPIKey { return "请填写蒲公英 API Key" }
        if usePgyerBuildNumber && !hasPgyerAppKey { return "请填写蒲公英 App Key" }
        if sendToFeishu && FeishuNotifier.validWebhook(feishuWebhook.trimmingCharacters(in: .whitespacesAndNewlines)) == nil { return "请填写有效的飞书机器人 Webhook" }
        if isLoadingPgyerBuildNumber { return "正在查询蒲公英 Build 号…" }
        return "配置已就绪，可以开始打包"
    }

    var canFetchPgyerBuildNumber: Bool {
        usePgyerBuildNumber &&
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

    private func schedulePgyerBuildLookup() {
        pgyerLookupTask?.cancel()
        pgyerLookupID = UUID()
        isLoadingPgyerBuildNumber = false
        guard usePgyerBuildNumber, !isPackaging, isValidVersionNumber,
              hasPgyerAPIKey, hasPgyerAppKey else { return }
        pgyerLookupTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            fetchNextBuildNumberFromPgyer()
        }
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
        guard usePgyerBuildNumber, !isPackaging else { return }
        let lookupID = UUID()
        pgyerLookupID = lookupID
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
                guard self.pgyerLookupID == lookupID else { return }
                self.isLoadingPgyerBuildNumber = false
                guard self.usePgyerBuildNumber, self.versionNumber.trimmingCharacters(in: .whitespacesAndNewlines) == version,
                      self.pgyerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines) == apiKey,
                      self.pgyerAppKey.trimmingCharacters(in: .whitespacesAndNewlines) == appKey else { return }
                self.buildNumber = String(nextBuild)
                self.statusMessage = "蒲公英版本 \(version) 的下一 Build 号：\(nextBuild)"
            } catch is CancellationError {
                guard self.pgyerLookupID == lookupID else { return }
                self.isLoadingPgyerBuildNumber = false
                self.statusMessage = "已取消查询蒲公英 Build 号"
            } catch {
                guard self.pgyerLookupID == lookupID else { return }
                self.isLoadingPgyerBuildNumber = false
                self.statusMessage = "蒲公英 Build 号查询失败：\(error.localizedDescription)"
            }
        }
    }

    func refreshBranches(fetchRemote: Bool = true) {
        guard !containerPath.isEmpty, !isLoadingBranches, !isPackaging, !isPreparing, pausedMerge == nil else { return }
        guard let projectAccess = restoreAccess(
            bookmarkKey: Keys.projectBookmark,
            fallbackPath: containerPath,
            directoryName: "项目目录"
        ) else {
            return
        }

        if fetchRemote { discardPreparedWorktree() }
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
                    let validMergeBranches = self.mergeBranches.filter {
                        branches.contains($0) && $0 != self.selectedBranch
                    }
                    if validMergeBranches != self.mergeBranches {
                        self.mergeBranches = validMergeBranches
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

    func setVersionNumberManually(_ value: String) {
        hasManualVersionOverride = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        versionNumber = value
    }

    func setBuildNumberManually(_ value: String) {
        guard !usePgyerBuildNumber else { return }
        buildLookupID = UUID()
        hasManualBuildOverride = !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        buildNumber = value
    }

    func refreshXcodeBuildNumber() {
        let lookupID = UUID()
        buildLookupID = lookupID
        guard !isPackaging else { return }
        hasManualBuildOverride = false

        let projectPath = containerPath
        let selectedScheme = scheme.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedConfiguration = configuration
        let selectedPlatform = platform
        guard !projectPath.isEmpty, !selectedScheme.isEmpty else {
            if !hasManualVersionOverride { versionNumber = "" }
            buildNumber = ""
            return
        }
        guard let projectAccess = restoreAccess(
            bookmarkKey: Keys.projectBookmark,
            fallbackPath: projectPath,
            directoryName: "项目目录"
        ) else { return }

        buildNumber = ""
        Task.detached(priority: .utility) {
            defer { projectAccess.stop() }
            do {
                let version = try XcodePackager.readBuildVersion(
                    containerPath: projectAccess.url.path,
                    scheme: selectedScheme,
                    configuration: selectedConfiguration.rawValue,
                    platform: selectedPlatform,
                    cancellation: BuildCancellationController()
                )
                await MainActor.run {
                    guard self.buildLookupID == lookupID, !self.isPackaging,
                          self.containerPath == projectPath, self.scheme == selectedScheme,
                          self.configuration == selectedConfiguration,
                          self.platform == selectedPlatform else { return }
                    if !self.hasManualVersionOverride {
                        self.versionNumber = version.marketingVersion
                    }
                    if !self.usePgyerBuildNumber {
                        self.buildNumber = version.currentProjectVersion
                    } else if !self.isLoadingPgyerBuildNumber {
                        self.schedulePgyerBuildLookup()
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.buildLookupID == lookupID, !self.isPackaging else { return }
                    self.statusMessage = "读取 Xcode Build 号失败：\(error.localizedDescription)"
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
                        self.scheme = schemes.first ?? ""
                    }
                    self.isLoadingSchemes = false
                    self.statusMessage = schemes.isEmpty
                        ? "当前工程没有可用的共享 Scheme，请在 Xcode 中检查 Scheme 配置"
                        : "已选择 Scheme：\(self.scheme)"
                    self.refreshXcodeBuildNumber()
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
        guard pausedMerge == nil else {
            statusMessage = "请先解决冲突或放弃并清理，再切换项目"
            return
        }
        let panel = NSOpenPanel()
        panel.title = AppStrings.text("选择 Xcode 项目文件夹")
        panel.message = AppStrings.text("请选择包含 .xcworkspace 或 .xcodeproj 的项目根目录")
        panel.prompt = AppStrings.text("选择项目文件夹")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = safePickerDirectory(preferredPath: containerPath)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveBookmark(for: url, key: Keys.projectBookmark)
        recordDirectory(url.path, isProject: true)
        applyProjectPath(url.path)
    }

    func selectProjectFromHistory(_ path: String) {
        guard projectDirectoryHistory.contains(path), pausedMerge == nil else { return }
        restoreHistoricalBookmark(for: path, isProject: true)
        recordDirectory(path, isProject: true)
        applyProjectPath(path)
    }

    private func applyProjectPath(_ path: String) {
        let projectChanged = projectSwitchKey(for: containerPath) != projectSwitchKey(for: path)
        if projectChanged { isRestoringProjectSwitches = true }
        containerPath = path
        if projectChanged {
            pgyerLookupTask?.cancel()
            pgyerLookupID = UUID()
            buildLookupID = UUID()
            hasManualVersionOverride = false
            hasManualBuildOverride = false
            scheme = ""
            availableSchemes = []
            versionNumber = ""
            buildNumber = ""
            remoteBranches = []
            selectedBranch = ""
            mergeBranches = []
            restoreProjectPlatform(for: path)
            restoreProjectSwitches(for: path)
            restoreOutputDirectory(for: path)
        }
        refreshSchemes()
        if useGitBranch {
            refreshBranches(fetchRemote: false)
        }
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = AppStrings.text("选择导出目录")
        panel.prompt = AppStrings.text("导出到这里")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = safePickerDirectory(preferredPath: outputDirectory)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveBookmark(for: url, key: Keys.outputBookmark)
        recordDirectory(url.path, isProject: false)
        setOutputDirectory(url.path)
        statusMessage = "导出目录已选择"
    }

    func selectOutputFromHistory(_ path: String) {
        guard outputDirectoryHistory.contains(path) else { return }
        restoreHistoricalBookmark(for: path, isProject: false)
        recordDirectory(path, isProject: false)
        setOutputDirectory(path)
        statusMessage = "导出目录已选择"
    }

    func refreshSigningProfiles() {
        guard !isPackaging else { return }
        let lookupID = UUID()
        signingLookupID = lookupID
        let projectPath = containerPath
        let selectedScheme = scheme.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedConfiguration = configuration.rawValue
        let shouldCheckProject = !projectPath.isEmpty && !selectedScheme.isEmpty
        let projectAccess = shouldCheckProject ? restoreAccess(
            bookmarkKey: Keys.projectBookmark,
            fallbackPath: projectPath,
            directoryName: "项目目录"
        ) : nil
        isLoadingSigningProfiles = true
        signingProfileBundleID = nil
        signingProfilesMessage = nil
        Task.detached(priority: .userInitiated) {
            defer { projectAccess?.stop() }
            var profiles: [ManualSigningProfile] = []
            var bundleID: String?
            var message: String?
            do {
                profiles = try ManualSigningProfile.installedProfiles()
            } catch {
                message = "读取 Xcode 描述文件失败：\(error.localizedDescription)"
            }
            if shouldCheckProject {
                if let projectAccess {
                    do {
                        bundleID = try XcodePackager.applicationBundleID(
                            containerPath: projectAccess.url.path, scheme: selectedScheme,
                            configuration: selectedConfiguration, cancellation: BuildCancellationController()
                        )
                    } catch {
                        message = [message, "无法核对当前工程：\(error.localizedDescription)"].compactMap { $0 }.joined(separator: "；")
                    }
                } else {
                    message = [message, "无法访问项目目录，请重新选择项目文件夹。"].compactMap { $0 }.joined(separator: "；")
                }
            } else {
                message = [message, "选择项目和 Scheme 后可查看匹配的描述文件。"].compactMap { $0 }.joined(separator: "；")
            }
            await MainActor.run {
                guard self.signingLookupID == lookupID,
                      self.containerPath == projectPath,
                      self.scheme == selectedScheme,
                      self.configuration.rawValue == selectedConfiguration else { return }
                self.installedSigningProfiles = ManualSigningProfile.eligibleProfiles(
                    from: profiles, bundleID: bundleID
                )
                self.signingProfileBundleID = bundleID
                self.signingProfilesMessage = message
                self.isLoadingSigningProfiles = false
            }
        }
    }

    func selectSigningProfile(_ profile: ManualSigningProfile) {
        guard !isPackaging else { return }
        guard let bundleID = signingProfileBundleID else {
            signingImportMessage = "请先选择工程和 Scheme，并刷新列表以核对 Bundle ID。"
            return
        }
        do {
            let installed = try ManualSigningProfile.load(uuid: profile.uuid)
            try installed.validate(bundleID: bundleID)
            signingProfileUUID = installed.uuid
            provisioningProfileName = installed.name
            signingImportMessage = "已选用 \(installed.name)；后续 iOS 打包将使用手动签名。"
        } catch {
            signingImportMessage = error.localizedDescription
        }
    }

    func clearSigningProfile() {
        signingProfileUUID = nil
        provisioningProfileName = nil
        signingImportMessage = "已清除指定描述文件，恢复工程原有签名方式。"
    }

    func importProvisioningProfile() {
        let panel = NSOpenPanel()
        panel.title = AppStrings.text("选择 iOS 描述文件")
        panel.prompt = AppStrings.text("导入描述文件")
        panel.allowedContentTypes = [UTType(filenameExtension: "mobileprovision") ?? .data]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let profile = try ManualSigningProfile.read(data)
            guard let bundleID = signingProfileBundleID else {
                throw PackageError.invalidInput("请先选择工程和 Scheme，并刷新列表以核对 Bundle ID。")
            }
            try profile.validate(bundleID: bundleID)
            let destination = ManualSigningProfile.installedURL(for: profile.uuid)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            provisioningProfileName = profile.name
            signingProfileUUID = profile.uuid
            signingImportMessage = "已选用 \(profile.name)；后续 iOS 打包将使用手动签名。"
            refreshSigningProfiles()
        } catch {
            signingImportMessage = error.localizedDescription
        }
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
        let enteredBuild = hasManualBuildOverride ? buildNumber.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let shouldUploadToPgyer = uploadToPgyer
        let shouldUsePgyerBuildNumber = usePgyerBuildNumber
        let shouldUseGitBranch = useGitBranch
        let shouldClearMergeSelection = !mergeBranches.isEmpty
        let branchToBuild = selectedBranch
        let shouldInstallPods = installPods
        let worktreeContext = preparedWorktree
        preparedWorktree = nil
        preparedConfiguration = nil
        hasPreparedWorktree = false
        let apiKey = pgyerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let appKey = pgyerAppKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let updateDescription = updateDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldSendToFeishu = sendToFeishu
        let webhook = feishuWebhook.trimmingCharacters(in: .whitespacesAndNewlines)
        let imageKey = feishuImageKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedSigningProfileUUID = platform == .iOS ? signingProfileUUID : nil

        isPackaging = true
        if shouldClearMergeSelection { mergeBranches = [] }
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
            var worktreeContext = worktreeContext
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
                    if worktreeContext == nil {
                        worktreeContext = try GitWorktreeManager.prepare(
                            projectPath: effectiveProjectPath,
                            branch: branchToBuild,
                            mergeBranches: [],
                            installPods: shouldInstallPods,
                            cancellation: cancellation
                        ) { chunk in logBuffer.append(chunk) }
                    } else {
                        logBuffer.append("===== 使用已准备并合并的临时 Worktree =====\n")
                    }
                    effectiveProjectPath = worktreeContext!.projectDirectory.path
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
                            "Build 号必须是大于 0 的整数，请检查手动填写值或 Xcode 的 CURRENT_PROJECT_VERSION。"
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
                    outputDirectory: outputAccess.url.path,
                    signingProfileUUID: selectedSigningProfileUUID,
                    isTemporaryProject: shouldUseGitBranch
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
                    self.recordPackage(PackageHistoryRecord(
                        id: UUID(),
                        completedAt: Date(),
                        scheme: scheme,
                        platform: platform.rawValue,
                        artifactPath: packageResult.artifactPath,
                        fileSize: packageResult.fileSize,
                        version: packageResult.versionNumber,
                        buildNumber: packageResult.buildNumber,
                        configuration: packageResult.configuration,
                        durationSeconds: self.elapsedSeconds,
                        downloadURL: uploadResult?.downloadURL
                    ))
                    self.defaults.set(build, forKey: Keys.lastSuccessfulBuild)
                    self.buildNumber = String(build)
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
        构建环境：\(packageResult.configuration)
        Version：\(packageResult.versionNumber)
        Build：\(packageResult.buildNumber)
        User：\(user)
        上传人：\(uploader)
        上传时间：\(formatter.string(from: uploadedAt))
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

    private func migrateDirectoryHistory(path: String, bookmarkKey: String,
                                         bookmarkHistoryKey: String, isProject: Bool) {
        guard !path.isEmpty else { return }
        recordDirectory(path, isProject: isProject)
        if let data = defaults.data(forKey: bookmarkKey) {
            var bookmarks = defaults.dictionary(forKey: bookmarkHistoryKey) as? [String: Data] ?? [:]
            if bookmarks[path] == nil {
                bookmarks[path] = data
                defaults.set(bookmarks, forKey: bookmarkHistoryKey)
            }
        }
    }

    private func recordDirectory(_ path: String, isProject: Bool) {
        let key = isProject ? Keys.projectDirectoryHistory : Keys.outputDirectoryHistory
        var history = isProject ? projectDirectoryHistory : outputDirectoryHistory
        history.removeAll { $0 == path }
        history.insert(path, at: 0)
        defaults.set(history, forKey: key)
        if isProject {
            projectDirectoryHistory = history
        } else {
            outputDirectoryHistory = history
        }
    }

    private func restoreHistoricalBookmark(for path: String, isProject: Bool) {
        let historyKey = isProject ? Keys.projectBookmarkHistory : Keys.outputBookmarkHistory
        let bookmarkKey = isProject ? Keys.projectBookmark : Keys.outputBookmark
        let bookmarks = defaults.dictionary(forKey: historyKey) as? [String: Data] ?? [:]
        if let data = bookmarks[path] {
            defaults.set(data, forKey: bookmarkKey)
        } else {
            defaults.removeObject(forKey: bookmarkKey)
        }
    }

    private func saveBookmark(for url: URL, key: String) {
        do {
            let data = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            defaults.set(data, forKey: key)
            let historyKey = key == Keys.projectBookmark
                ? Keys.projectBookmarkHistory : Keys.outputBookmarkHistory
            var bookmarks = defaults.dictionary(forKey: historyKey) as? [String: Data] ?? [:]
            bookmarks[url.standardizedFileURL.path] = data
            defaults.set(bookmarks, forKey: historyKey)
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

    private func recordPackage(_ record: PackageHistoryRecord) {
        do {
            let updated = [record] + packageHistory
            try historyStore.save(updated)
            packageHistory = updated
            historyError = nil
        } catch {
            historyError = "保存打包历史失败：\(error.localizedDescription)"
        }
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
