import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SymbolUploadView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: PackagerViewModel
    let record: PackageHistoryRecord
    @State private var appID = ""
    @State private var appKey = ""
    @State private var toolPath = ""
    @State private var symbolPath = ""
    @State private var message = ""
    @State private var output = ""
    @State private var isUploading = false
    @State private var uploadTask: Task<Void, Never>?

    private var settingsKey: String { "symbolUpload.bugly.\(record.scheme)" }
    private var credentialAccount: String { "bugly.\(appID.trimmingCharacters(in: .whitespacesAndNewlines))" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("上传 dSYM 到 Bugly").font(.title2.bold())
                Spacer()
                Button("关闭") { dismiss() }.disabled(isUploading)
            }
            Text("\(record.scheme) · v\(record.version) · Build \(record.buildNumber)")
                .foregroundStyle(.secondary)
            Form {
                TextField("Bugly App ID", text: $appID)
                SecureField("Bugly App Key", text: $appKey)
                HStack {
                    TextField("官方上传工具 (.jar)", text: $toolPath)
                    Button("选择") { chooseTool() }
                }
                HStack {
                    TextField("dSYM 文件或目录", text: $symbolPath)
                    Button("选择") { chooseSymbols() }
                }
            }
            .disabled(isUploading)
            Text("使用 Bugly 官方 buglyqq-upload-symbol.jar，需安装 Java。App Key 保存到钥匙串；请确认目标 App ID 属于此历史版本。工具正常退出后仍建议在 Bugly 后台确认符号处理结果。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Link("下载 Bugly 官方符号上传工具", destination: URL(string: "https://bugly.qq.com/v2/downloads")!)
            if !message.isEmpty {
                Text(message).font(.callout).textSelection(.enabled)
            }
            if !output.isEmpty {
                ScrollView {
                    Text(output)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140)
            }
            HStack {
                if isUploading {
                    ProgressView().controlSize(.small)
                    Text("正在运行 Bugly 上传工具…")
                    Spacer()
                    Button("取消上传") { uploadTask?.cancel() }
                } else {
                    Spacer()
                    Button("上传到 Bugly") { startUpload() }
                        .buttonStyle(.borderedProminent)
                        .disabled([appID, appKey, toolPath, symbolPath].contains {
                            $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        })
                }
            }
        }
        .padding(24)
        .frame(width: 620)
        .interactiveDismissDisabled(isUploading)
        .onAppear { loadSettings() }
        .onChange(of: appID) { _, _ in
            do { appKey = try SymbolCredentialStore.load(account: credentialAccount) }
            catch { appKey = ""; message = error.localizedDescription }
        }
        .onDisappear { uploadTask?.cancel() }
    }

    private func loadSettings() {
        let defaults = UserDefaults.standard
        appID = defaults.string(forKey: settingsKey + ".appID") ?? ""
        toolPath = defaults.string(forKey: "symbolUpload.bugly.toolPath") ?? ""
        symbolPath = SymbolFiles.defaultDirectory(artifactPath: record.artifactPath).path
        do { appKey = try SymbolCredentialStore.load(account: credentialAccount) }
        catch { message = error.localizedDescription }
    }

    private func chooseTool() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "jar") ?? .data]
        if panel.runModal() == .OK, let url = panel.url { toolPath = url.path }
    }

    private func chooseSymbols() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.treatsFilePackagesAsDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择 .dSYM 或包含多个 .dSYM 的目录"
        if panel.runModal() == .OK, let url = panel.url { symbolPath = url.path }
    }

    private func startUpload() {
        guard !isUploading else { return }
        let request = SymbolUploadRequest(
            symbolURL: URL(fileURLWithPath: symbolPath.trimmingCharacters(in: .whitespacesAndNewlines)),
            version: record.version,
            appID: appID.trimmingCharacters(in: .whitespacesAndNewlines),
            appKey: appKey.trimmingCharacters(in: .whitespacesAndNewlines),
            toolURL: URL(fileURLWithPath: toolPath.trimmingCharacters(in: .whitespacesAndNewlines))
        )
        do {
            try SymbolFiles.validate(request.symbolURL)
            try SymbolCredentialStore.save(request.appKey, account: credentialAccount)
        } catch {
            message = error.localizedDescription
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(request.appID, forKey: settingsKey + ".appID")
        defaults.set(request.toolURL.path, forKey: "symbolUpload.bugly.toolPath")
        isUploading = true
        message = ""
        output = ""
        uploadTask = Task {
            defer { isUploading = false; uploadTask = nil }
            do {
                let uploader: any SymbolUploader = BuglySymbolUploader()
                let result = try await uploader.upload(request)
                output = result.output
                do {
                    try viewModel.recordSymbolUpload(recordID: record.id, result: result)
                    message = "Bugly 上传工具执行完成，请在 Bugly 后台确认符号处理结果。"
                } catch {
                    message = "工具执行完成，但保存历史状态失败：\(error.localizedDescription)"
                }
            } catch is CancellationError {
                message = "已取消上传。已发送的数据可能仍由 Bugly 处理。"
            } catch {
                message = error.localizedDescription
            }
        }
    }
}
