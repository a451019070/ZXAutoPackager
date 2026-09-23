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

struct PackageRequest: Sendable {
    let containerPath: String
    let scheme: String
    let configuration: String
    let versionNumber: String
    let buildNumber: Int
    let outputDirectory: String
}

struct PackageResult: Sendable {
    let artifactPath: String
    let log: String
}

enum PackageError: LocalizedError {
    case invalidInput(String)
    case commandFailed(Int32, String)
    case productNotFound(String)

    var errorDescription: String? {
        switch self {
        case .invalidInput(let message):
            return message
        case .commandFailed(let code, let log):
            return "构建失败（退出码 \(code)）\n\(log)"
        case .productNotFound(let log):
            return "归档完成，但没有找到导出的 .ipa。\n\(log)"
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
    @Published var configuration: Configuration = .release {
        didSet { defaults.set(configuration.rawValue, forKey: Keys.configuration) }
    }
    @Published var versionNumber = "1.0" {
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
    @Published var pgyerAPIKey = "" {
        didSet { defaults.set(pgyerAPIKey, forKey: Keys.pgyerAPIKey) }
    }
    @Published var updateDescription = "" {
        didSet { defaults.set(updateDescription, forKey: Keys.updateDescription) }
    }
    @Published var isPackaging = false
    @Published var elapsedSeconds = 0
    @Published var statusMessage = "请选择工程和导出目录"
    @Published var log = ""
    @Published var lastArtifactPath: String?
    @Published var pgyerDownloadURL: String?
    @Published var isShowingQRCode = false

    private enum Keys {
        static let containerPath = "ZXAutoPackager.containerPath"
        static let scheme = "ZXAutoPackager.scheme"
        static let configuration = "ZXAutoPackager.configuration"
        static let versionNumber = "ZXAutoPackager.versionNumber"
        static let buildNumber = "ZXAutoPackager.buildNumber"
        static let outputDirectory = "ZXAutoPackager.outputDirectory"
        static let uploadToPgyer = "ZXAutoPackager.uploadToPgyer"
        static let pgyerAPIKey = "ZXAutoPackager.pgyerAPIKey"
        static let updateDescription = "ZXAutoPackager.updateDescription"
        static let lastSuccessfulBuild = "ZXAutoPackager.lastSuccessfulBuild"
    }

    private let defaults = UserDefaults.standard
    private let maximumLogLength = 300_000
    private var logRefreshTask: Task<Void, Never>?
    private var elapsedTimeTask: Task<Void, Never>?

    deinit {
        logRefreshTask?.cancel()
        elapsedTimeTask?.cancel()
    }

    init() {
        containerPath = defaults.string(forKey: Keys.containerPath) ?? ""
        scheme = defaults.string(forKey: Keys.scheme) ?? ""
        configuration = Configuration(
            rawValue: defaults.string(forKey: Keys.configuration) ?? ""
        ) ?? .release
        versionNumber = defaults.string(forKey: Keys.versionNumber) ?? "1.0"
        outputDirectory = defaults.string(forKey: Keys.outputDirectory) ?? ""
        uploadToPgyer = defaults.bool(forKey: Keys.uploadToPgyer)
        pgyerAPIKey = defaults.string(forKey: Keys.pgyerAPIKey) ?? ""
        updateDescription = defaults.string(forKey: Keys.updateDescription) ?? ""

        if let savedBuild = defaults.string(forKey: Keys.buildNumber), !savedBuild.isEmpty {
            buildNumber = savedBuild
        } else {
            let lastBuild = defaults.integer(forKey: Keys.lastSuccessfulBuild)
            buildNumber = String(max(lastBuild + 1, 1))
        }

        if !containerPath.isEmpty || !outputDirectory.isEmpty {
            statusMessage = "已恢复上次填写的打包配置"
        }
    }

    var canPackage: Bool {
        !isPackaging &&
        !containerPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        isValidVersionNumber &&
        Int(buildNumber).map { $0 > 0 } == true &&
        !outputDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        (!uploadToPgyer || !pgyerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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

    func chooseProject() {
        let panel = NSOpenPanel()
        panel.title = "选择 Xcode 项目文件夹"
        panel.message = "请选择包含 .xcworkspace 或 .xcodeproj 的项目根目录"
        panel.prompt = "选择项目文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        containerPath = url.path
        if scheme.isEmpty {
            scheme = url.lastPathComponent
        }
        statusMessage = "项目文件夹已选择，将自动识别 Xcode 工程"
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择导出目录"
        panel.prompt = "导出到这里"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDirectory = url.path
        statusMessage = "导出目录已选择"
    }

    func startPackaging() {
        guard isValidVersionNumber else {
            statusMessage = "版本号格式不正确，例如：1.0 或 1.2.3"
            return
        }
        guard let build = Int(buildNumber), build > 0 else {
            statusMessage = "Build 号必须是大于 0 的整数"
            return
        }
        guard canPackage else {
            statusMessage = "请完整填写工程、Scheme、Build 号和导出目录"
            return
        }

        let request = PackageRequest(
            containerPath: containerPath,
            scheme: scheme.trimmingCharacters(in: .whitespacesAndNewlines),
            configuration: configuration.rawValue,
            versionNumber: versionNumber.trimmingCharacters(in: .whitespacesAndNewlines),
            buildNumber: build,
            outputDirectory: outputDirectory
        )

        let shouldUploadToPgyer = uploadToPgyer
        let pgyerRequest = PgyerUploadRequest(
            apiKey: pgyerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines),
            ipaPath: "",
            updateDescription: updateDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        isPackaging = true
        elapsedSeconds = 0
        startElapsedTimer()
        lastArtifactPath = nil
        pgyerDownloadURL = nil
        log = ""
        statusMessage = "正在归档并导出 \(configuration.rawValue) IPA…"

        let logBuffer = BuildLogBuffer()
        startLogRefresh(from: logBuffer)

        Task.detached(priority: .userInitiated) {
            do {
                let packageResult = try XcodePackager.package(request) { chunk in
                    logBuffer.append(chunk)
                }

                var uploadResult: PgyerUploadResult?
                if shouldUploadToPgyer {
                    let uploadRequest = PgyerUploadRequest(
                        apiKey: pgyerRequest.apiKey,
                        ipaPath: packageResult.artifactPath,
                        updateDescription: pgyerRequest.updateDescription
                    )
                    uploadResult = try await PgyerUploader.upload(uploadRequest) { chunk in
                        logBuffer.append(chunk)
                    }
                }

                await MainActor.run {
                    self.finishLogRefresh(from: logBuffer)
                    self.stopElapsedTimer()
                    self.isPackaging = false
                    self.lastArtifactPath = packageResult.artifactPath
                    self.pgyerDownloadURL = uploadResult?.downloadURL
                    if let uploadResult {
                        self.statusMessage = "上传成功：\(uploadResult.appName) \(uploadResult.version)"
                    } else {
                        self.statusMessage = "打包成功：\(URL(fileURLWithPath: packageResult.artifactPath).lastPathComponent)"
                    }
                    self.defaults.set(build, forKey: Keys.lastSuccessfulBuild)
                    self.buildNumber = String(build + 1)
                }
            } catch {
                await MainActor.run {
                    self.finishLogRefresh(from: logBuffer)
                    self.stopElapsedTimer()
                    self.isPackaging = false
                    let summary = self.errorSummary(error)
                    self.appendLog("\n\n===== 打包失败 =====\n\(summary)\n")
                    self.statusMessage = "打包失败，请查看日志末尾"
                }
            }
        }
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

    private func errorSummary(_ error: Error) -> String {
        if case PackageError.commandFailed(let code, _) = error {
            return "构建命令退出码：\(code)。详细错误请查看上方日志末尾。"
        }
        if case PackageError.productNotFound = error {
            return "归档完成，但没有找到导出的 IPA。"
        }
        return error.localizedDescription
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
