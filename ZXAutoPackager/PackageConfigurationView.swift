import SwiftUI

struct PackageConfigurationView: View {
    @ObservedObject var viewModel: PackagerViewModel
    @State private var showAdvancedOptions = false
    @State private var showPgyerSettings = false
    @State private var showFeishuSettings = false
    @State private var showSigningSettings = false

    var body: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 16) {
                GridRow {
                    fieldTitle("项目文件夹")
                    pathField(
                        viewModel.containerPath,
                        placeholder: "请选择包含 Xcode 工程的项目根目录",
                        action: viewModel.chooseProject
                    )
                }

                GridRow {
                    fieldTitle("Scheme")
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            schemeControls
                            versionBuildControls
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            schemeControls
                            versionBuildControls
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GridRow {
                    fieldTitle("导出目录")
                    pathField(
                        viewModel.outputDirectory,
                        placeholder: "请选择产物保存目录",
                        action: viewModel.chooseOutputDirectory
                    )
                }

                GridRow {
                    fieldTitle("目标平台")
                    HStack(spacing: 12) {
                        Picker("目标平台", selection: $viewModel.platform) {
                            ForEach(PackagePlatform.allCases) { platform in
                                Text(platform.rawValue).tag(platform)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                        Text(viewModel.platform == .iOS ? "导出 IPA" : "导出 macOS 应用 ZIP")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                GridRow {
                    fieldTitle("构建环境")
                    HStack(spacing: 12) {
                        Picker("构建环境", selection: $viewModel.configuration) {
                            ForEach(PackagerViewModel.Configuration.allCases) { item in
                                Text(item.rawValue).tag(item)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                        Text("默认 Release")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }

                if viewModel.platform == .iOS && viewModel.uploadToPgyer {
                    GridRow {
                        fieldTitle("更新说明")
                        TextField("可选，本次版本更新内容", text: $viewModel.updateDescription)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            .padding(8)
        } label: {
            HStack(spacing: 10) {
                Label("打包配置", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                if !enabledOptions.isEmpty {
                    Button {
                        showAdvancedOptions = true
                    } label: {
                        Text(enabledOptions.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(optionsNeedSetup ? .orange : .secondary)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(optionsNeedSetup ? "已开启的选项中有待配置项；点击查看高级选项" : "已开启的选项；点击查看高级选项")
                }
                Button("高级选项…") { showAdvancedOptions = true }
            }
        }
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showAdvancedOptions) {
            advancedSettings
        }
        .onChange(of: viewModel.containerPath) { _, _ in
            if showSigningSettings { viewModel.refreshSigningProfiles() }
            viewModel.refreshXcodeBuildNumber()
        }
        .onChange(of: viewModel.scheme) { _, _ in
            if showSigningSettings { viewModel.refreshSigningProfiles() }
            viewModel.refreshXcodeBuildNumber()
        }
        .onChange(of: viewModel.configuration) { _, _ in
            if showSigningSettings { viewModel.refreshSigningProfiles() }
            viewModel.refreshXcodeBuildNumber()
        }
        .onChange(of: viewModel.platform) { _, _ in
            viewModel.refreshXcodeBuildNumber()
        }
    }

    private var schemeControls: some View {
        HStack(spacing: 6) {
            if viewModel.availableSchemes.isEmpty {
                TextField("例如：MyApp", text: $viewModel.scheme)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 130)
            } else {
                Picker("Scheme", selection: $viewModel.scheme) {
                    Text("请选择 Scheme").tag("")
                    ForEach(viewModel.availableSchemes, id: \.self) { scheme in
                        Text(scheme).tag(scheme)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            Button(viewModel.isLoadingSchemes ? "读取中…" : "刷新") {
                viewModel.refreshSchemes()
            }
            .disabled(viewModel.containerPath.isEmpty || viewModel.isLoadingSchemes || viewModel.isPackaging || viewModel.isPreparing || viewModel.mergeConflictBranch != nil)
        }
    }

    private var versionBuildControls: some View {
        HStack(spacing: 8) {
            Text("版本号")
                .fixedSize()
            TextField("Xcode 默认", text: $viewModel.versionNumber)
                .textFieldStyle(.roundedBorder)
                .frame(width: 86)
                .help("留空时读取 Xcode 的 MARKETING_VERSION")
            Text("Build 号")
                .fixedSize()
            TextField(viewModel.usePgyerBuildNumber ? "打包前查询" : "Xcode 默认", text: Binding(
                get: { viewModel.buildNumber },
                set: { viewModel.setBuildNumberManually($0) }
            ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 82)
                .disabled(viewModel.usePgyerBuildNumber)
                .help(viewModel.usePgyerBuildNumber ? "打包前获取蒲公英当前版本最大 Build 号 +1" : "默认显示并使用 Xcode 的 CURRENT_PROJECT_VERSION；可手动修改，清空后打包仍使用 Xcode 默认值，不自动 +1")
            if viewModel.platform == .iOS {
                Button(viewModel.isLoadingPgyerBuildNumber ? "查询中…" : "查询") {
                    viewModel.fetchNextBuildNumberFromPgyer()
                }
                .disabled(!viewModel.canFetchPgyerBuildNumber)
                .help("查询蒲公英 Build 号")
                Toggle("从蒲公英获取", isOn: $viewModel.usePgyerBuildNumber)
                    .toggleStyle(.switch)
                    .fixedSize()
                    .help("打包前从蒲公英自动获取 Build 号")
            }
        }
    }

    private var enabledOptions: [String] {
        var options: [String] = []
        if viewModel.useGitBranch { options.append("Worktree") }
        if viewModel.platform == .iOS && viewModel.signingProfileUUID != nil { options.append("手动签名") }
        if viewModel.platform == .iOS && viewModel.uploadToPgyer { options.append("蒲公英") }
        if viewModel.sendToFeishu { options.append("飞书") }
        return options
    }

    private var optionsNeedSetup: Bool {
        (viewModel.useGitBranch && viewModel.selectedBranch.isEmpty) ||
        (viewModel.platform == .iOS && viewModel.signingProfileUUID != nil && viewModel.provisioningProfileName == nil) ||
        (viewModel.platform == .iOS && viewModel.uploadToPgyer && pgyerNeedsSetup) ||
        feishuNeedsSetup
    }

    private var pgyerNeedsSetup: Bool {
        let apiKeyMissing = viewModel.pgyerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let appKeyMissing = viewModel.usePgyerBuildNumber && viewModel.pgyerAppKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (viewModel.uploadToPgyer || viewModel.usePgyerBuildNumber) && (apiKeyMissing || appKeyMissing)
    }

    private var pgyerStatus: String {
        if pgyerNeedsSetup { return "待配置" }
        if viewModel.uploadToPgyer || viewModel.usePgyerBuildNumber { return "已启用 · 已配置" }
        return viewModel.pgyerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未配置" : "已配置"
    }

    private var feishuNeedsSetup: Bool {
        viewModel.sendToFeishu && FeishuNotifier.validWebhook(viewModel.feishuWebhook.trimmingCharacters(in: .whitespacesAndNewlines)) == nil
    }

    private var feishuStatus: String {
        if feishuNeedsSetup { return "待配置" }
        if viewModel.sendToFeishu { return "已启用 · 已配置" }
        return FeishuNotifier.validWebhook(viewModel.feishuWebhook.trimmingCharacters(in: .whitespacesAndNewlines)) == nil ? "未配置" : "已配置"
    }

    private var signingProfileSelection: Binding<String> {
        Binding(
            get: { viewModel.signingProfileUUID ?? "" },
            set: { uuid in
                if uuid.isEmpty {
                    viewModel.clearSigningProfile()
                } else if let profile = viewModel.installedSigningProfiles.first(where: { $0.uuid == uuid }) {
                    viewModel.selectSigningProfile(profile)
                }
            }
        )
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("高级选项")
                .font(.title3.bold())
            ScrollView {
                advancedOptions
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("完成") { showAdvancedOptions = false }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 680)
        .frame(maxHeight: 620)
    }

    private var advancedOptions: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                fieldTitle("多分支")
                Toggle("使用独立 Worktree 打包", isOn: $viewModel.useGitBranch)
                    .toggleStyle(.switch)
                    .disabled(viewModel.mergeConflictBranch != nil || viewModel.isPreparing)
                    .onChange(of: viewModel.useGitBranch) { _, enabled in
                        if enabled && viewModel.remoteBranches.isEmpty {
                            viewModel.refreshBranches(fetchRemote: false)
                        }
                    }
            }

            if viewModel.useGitBranch {
                GridRow {
                    fieldTitle("远程分支")
                    HStack {
                        Picker("远程分支", selection: $viewModel.selectedBranch) {
                            if viewModel.remoteBranches.isEmpty {
                                Text("暂无分支").tag("")
                            } else {
                                ForEach(viewModel.remoteBranches, id: \.self) { branch in
                                    Text(branch).tag(branch)
                                }
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                        .disabled(viewModel.mergeConflictBranch != nil || viewModel.isPreparing)

                        Button(viewModel.isLoadingBranches ? "刷新中…" : "刷新") {
                            viewModel.refreshBranches()
                        }
                        .disabled(viewModel.isLoadingBranches || viewModel.isPackaging || viewModel.isPreparing || viewModel.mergeConflictBranch != nil)
                    }
                }

                GridRow {
                    fieldTitle("合并分支")
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(viewModel.mergeBranches.enumerated()), id: \.element) { index, branch in
                            HStack {
                                Text("\(index + 1). \(branch)")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("上移", systemImage: "arrow.up") {
                                    viewModel.mergeBranches.swapAt(index, index - 1)
                                }
                                .disabled(index == 0 || viewModel.isPackaging || viewModel.isPreparing || viewModel.mergeConflictBranch != nil)
                                Button("下移", systemImage: "arrow.down") {
                                    viewModel.mergeBranches.swapAt(index, index + 1)
                                }
                                .disabled(index == viewModel.mergeBranches.count - 1 || viewModel.isPackaging || viewModel.isPreparing || viewModel.mergeConflictBranch != nil)
                                Button("移除", systemImage: "minus.circle") {
                                    viewModel.mergeBranches.remove(at: index)
                                }
                                .disabled(viewModel.isPackaging || viewModel.isPreparing || viewModel.mergeConflictBranch != nil)
                            }
                            .labelStyle(.iconOnly)
                        }
                        Menu("添加合并分支…") {
                            ForEach(viewModel.remoteBranches.filter {
                                $0 != viewModel.selectedBranch && !viewModel.mergeBranches.contains($0)
                            }, id: \.self) { branch in
                                Button(branch) { viewModel.mergeBranches.append(branch) }
                            }
                        }
                        .disabled(viewModel.isPackaging || viewModel.isPreparing || viewModel.isLoadingBranches ||
                            viewModel.mergeConflictBranch != nil || viewModel.remoteBranches.allSatisfy {
                                $0 == viewModel.selectedBranch || viewModel.mergeBranches.contains($0)
                            })
                        Text(viewModel.mergeBranches.isEmpty
                             ? "不合并其他分支，可直接打包所选远程分支。"
                             : "已选择合并分支，请先“准备并合并”再打包；冲突会停止准备。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GridRow {
                    fieldTitle("依赖")
                    Toggle("临时 Worktree 中执行 pod install", isOn: $viewModel.installPods)
                }

                if !viewModel.mergeBranches.isEmpty || viewModel.isPreparing {
                    GridRow {
                        fieldTitle("代码准备")
                        HStack(spacing: 12) {
                            if viewModel.isPreparing {
                                ProgressView()
                                    .controlSize(.small)
                                if viewModel.mergeConflictBranch == nil {
                                    Button("停止准备", role: .destructive, action: viewModel.stopPreparing)
                                } else {
                                    Text("正在继续合并…").font(.caption)
                                }
                            } else if let branch = viewModel.mergeConflictBranch {
                                Label("origin/\(branch) 冲突", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Button("打开临时目录", action: viewModel.openConflictWorktree)
                                Button("检查并继续", action: viewModel.continueMerge)
                                Button("放弃并清理", role: .destructive, action: viewModel.discardMergeConflict)
                            } else {
                                Button(viewModel.hasPreparedWorktree ? "重新准备" : "准备并合并",
                                       action: viewModel.prepareBranches)
                                    .disabled(!viewModel.canPrepareBranches)
                            }
                            if viewModel.hasPreparedWorktree {
                                Label("已准备完成，可开始打包", systemImage: "checkmark.circle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }
                if viewModel.mergeConflictBranch != nil {
                    GridRow {
                        fieldTitle("冲突文件")
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(viewModel.mergeConflictFiles, id: \.self) { file in
                                Text(file).font(.caption.monospaced()).textSelection(.enabled)
                            }
                            Text("在临时目录修改冲突文件，执行 git add 标记已解决，然后点击“检查并继续”。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if viewModel.platform == .iOS {
                GridRow {
                    fieldTitle("蒲公英")
                    HStack(spacing: 12) {
                        Toggle("打包后上传蒲公英", isOn: $viewModel.uploadToPgyer)
                            .toggleStyle(.switch)
                        Spacer()
                        Text(pgyerStatus)
                            .font(.caption)
                            .foregroundStyle(pgyerNeedsSetup ? .orange : .secondary)
                        Button(showPgyerSettings ? "收起配置" : "配置…") {
                            showPgyerSettings.toggle()
                        }
                    }
                }
                if showPgyerSettings {
                    GridRow {
                        fieldTitle("API Key")
                        SecureField("蒲公英 API Key", text: $viewModel.pgyerAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        fieldTitle("App Key")
                        VStack(alignment: .leading, spacing: 4) {
                            SecureField("蒲公英应用 App Key", text: $viewModel.pgyerAppKey)
                                .textFieldStyle(.roundedBorder)
                            Text("仅从蒲公英查询 Build 号时需要 App Key。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            GridRow {
                fieldTitle("飞书")
                HStack(spacing: 12) {
                    Toggle("打包后发送飞书通知", isOn: $viewModel.sendToFeishu)
                        .toggleStyle(.switch)
                    Spacer()
                    Text(feishuStatus)
                        .font(.caption)
                        .foregroundStyle(feishuNeedsSetup ? .orange : .secondary)
                    Button(showFeishuSettings ? "收起配置" : "配置…") {
                        showFeishuSettings.toggle()
                    }
                }
            }
            if showFeishuSettings {
                GridRow {
                    fieldTitle("Webhook")
                    SecureField("飞书群自定义机器人 Webhook 地址", text: $viewModel.feishuWebhook)
                        .textFieldStyle(.roundedBorder)
                }
                GridRow {
                    fieldTitle("imageKey")
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("可选，填写已上传至飞书的图片 imageKey", text: $viewModel.feishuImageKey)
                            .textFieldStyle(.roundedBorder)
                        if viewModel.feishuImageKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Link("点击获取 imageKey", destination: URL(string: "https://open.larkoffice.com/cardkit")!)
                        }
                        Text("卡片使用已有 imageKey 显示图片；不会自动上传本次下载地址的二维码。下载地址来自蒲公英。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if viewModel.platform == .iOS {
                GridRow {
                    fieldTitle("签名方式")
                    HStack {
                        Text(viewModel.signingProfileUUID == nil ? "使用工程原有签名" : "指定描述文件 · 手动签名")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        Button(showSigningSettings ? "收起" : "配置…") {
                            showSigningSettings.toggle()
                            if showSigningSettings { viewModel.refreshSigningProfiles() }
                        }
                        .disabled(viewModel.isPackaging || viewModel.isPreparing || viewModel.mergeConflictBranch != nil)
                    }
                }
                if showSigningSettings {
                    GridRow {
                        fieldTitle("描述文件")
                        HStack(spacing: 8) {
                            Picker("描述文件", selection: signingProfileSelection) {
                                Text("使用工程原有签名").tag("")
                                if let selectedUUID = viewModel.signingProfileUUID,
                                   !viewModel.installedSigningProfiles.contains(where: { $0.uuid == selectedUUID }) {
                                    Text(viewModel.provisioningProfileName ?? "所选文件失效，请重新选择")
                                        .tag(selectedUUID)
                                }
                                ForEach(viewModel.installedSigningProfiles, id: \.uuid) { profile in
                                    Text("\(profile.name) · \(profile.exportMethod) · 到期 \(profile.expiration.formatted(date: .abbreviated, time: .omitted))")
                                        .tag(profile.uuid)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                            .disabled(viewModel.isPackaging || viewModel.isLoadingSigningProfiles)
                            Button(viewModel.isLoadingSigningProfiles ? "读取中…" : "刷新") {
                                viewModel.refreshSigningProfiles()
                            }
                            .disabled(viewModel.isPackaging || viewModel.isLoadingSigningProfiles)
                        }
                    }
                    GridRow {
                        fieldTitle("")
                        VStack(alignment: .leading, spacing: 6) {
                            if let message = viewModel.signingProfilesMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if viewModel.installedSigningProfiles.isEmpty && !viewModel.isLoadingSigningProfiles && viewModel.signingProfileBundleID != nil {
                                Text("没有找到与当前工程匹配的可用描述文件（需未过期且钥匙串中有匹配私钥）。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("从文件导入…") { viewModel.importProvisioningProfile() }
                                .disabled(viewModel.isPackaging || viewModel.signingProfileBundleID == nil || viewModel.isLoadingSigningProfiles)
                            Text("使用钥匙串中与描述文件匹配的证书和私钥。选择后持续用于 iOS 手动签名，不修改工程；目前仅支持不含 Extension 的单 App。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let message = viewModel.signingImportMessage {
                                Text(message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func fieldTitle(_ title: String) -> some View {
        Text(title)
            .fontWeight(.medium)
            .frame(width: 86, alignment: .trailing)
    }

    private func pathField(
        _ value: String,
        placeholder: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack {
            Text(value.isEmpty ? placeholder : value)
                .foregroundStyle(value.isEmpty ? .tertiary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9)
                .frame(height: 28)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.quaternary)
                }
            Button("选择…", action: action)
        }
    }
}
