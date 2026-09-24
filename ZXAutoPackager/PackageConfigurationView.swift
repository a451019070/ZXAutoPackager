import SwiftUI

struct PackageConfigurationView: View {
    @ObservedObject var viewModel: PackagerViewModel
    @State private var showAdvancedOptions = false

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
                    HStack {
                        if viewModel.availableSchemes.isEmpty {
                            TextField("例如：MyApp", text: $viewModel.scheme)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            Picker("Scheme", selection: $viewModel.scheme) {
                                Text("请选择 Scheme").tag("")
                                ForEach(viewModel.availableSchemes, id: \.self) { scheme in
                                    Text(scheme).tag(scheme)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                        }
                        Button(viewModel.isLoadingSchemes ? "读取中…" : "刷新") {
                            viewModel.refreshSchemes()
                        }
                        .disabled(viewModel.containerPath.isEmpty || viewModel.isLoadingSchemes || viewModel.isPackaging)
                    }
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

                GridRow {
                    DisclosureGroup(isExpanded: $showAdvancedOptions) {
                        advancedOptions
                            .padding(.top, 12)
                    } label: {
                        Label("高级选项", systemImage: "slider.horizontal.3")
                            .fontWeight(.medium)
                    }
                    .gridCellColumns(2)
                }

                if viewModel.platform == .iOS {
                    GridRow {
                        fieldTitle("蒲公英")
                        Toggle("打包后上传蒲公英", isOn: $viewModel.uploadToPgyer)
                            .toggleStyle(.switch)
                    }
                }

                if viewModel.platform == .iOS && (viewModel.uploadToPgyer || viewModel.usePgyerBuildNumber) {
                    GridRow {
                        fieldTitle("API Key")
                        SecureField("蒲公英 API Key", text: $viewModel.pgyerAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if viewModel.platform == .iOS && viewModel.usePgyerBuildNumber {
                    GridRow {
                        fieldTitle("App Key")
                        SecureField("蒲公英应用 App Key", text: $viewModel.pgyerAppKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if viewModel.platform == .iOS && viewModel.uploadToPgyer {
                    GridRow {
                        fieldTitle("更新说明")
                        TextField("可选，本次版本更新内容", text: $viewModel.updateDescription)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                GridRow {
                    fieldTitle("飞书")
                    Toggle("打包后发送飞书通知", isOn: $viewModel.sendToFeishu)
                        .toggleStyle(.switch)
                }
                if viewModel.sendToFeishu {
                    GridRow {
                        fieldTitle("Webhook")
                        SecureField("飞书群自定义机器人 Webhook 地址", text: $viewModel.feishuWebhook)
                            .textFieldStyle(.roundedBorder)
                    }
                    GridRow {
                        fieldTitle("图片 imageKey")
                        HStack {
                            TextField("可选，填写已上传至飞书的图片 imageKey", text: $viewModel.feishuImageKey)
                                .textFieldStyle(.roundedBorder)
                            if viewModel.feishuImageKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Link("点击获取 imageKey", destination: URL(string: "https://open.larkoffice.com/cardkit")!)
                            }
                        }
                    }
                    GridRow {
                        Text("")
                        Text("卡片使用已有 imageKey 显示图片；不会自动上传本次下载地址的二维码。下载地址来自蒲公英。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
        } label: {
            Label("打包配置", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
    }

    private var advancedOptions: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 14) {
            GridRow {
                fieldTitle("多分支")
                Toggle("使用独立 Worktree 打包", isOn: $viewModel.useGitBranch)
                    .toggleStyle(.switch)
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

                        Button(viewModel.isLoadingBranches ? "刷新中…" : "刷新") {
                            viewModel.refreshBranches()
                        }
                        .disabled(viewModel.isLoadingBranches || viewModel.isPackaging)
                    }
                }

                GridRow {
                    fieldTitle("依赖")
                    Toggle("临时 Worktree 中执行 pod install", isOn: $viewModel.installPods)
                }
            }

            GridRow {
                fieldTitle("版本号")
                HStack {
                    TextField("例如：1.0.0", text: $viewModel.versionNumber)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                    Text("留空时读取 Xcode 的 MARKETING_VERSION")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            GridRow {
                fieldTitle("Build 号")
                HStack {
                    TextField("Build", text: $viewModel.buildNumber)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                        .disabled(viewModel.usePgyerBuildNumber)
                    if viewModel.platform == .iOS {
                        Button(viewModel.isLoadingPgyerBuildNumber ? "查询中…" : "查询蒲公英") {
                            viewModel.fetchNextBuildNumberFromPgyer()
                        }
                        .disabled(!viewModel.canFetchPgyerBuildNumber)
                    }
                    Text(viewModel.usePgyerBuildNumber
                         ? "打包前自动使用当前 Version 的远端最大值 +1"
                         : "留空时读取 Xcode 的 CURRENT_PROJECT_VERSION")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            if viewModel.platform == .iOS {
                GridRow {
                    fieldTitle("Build 来源")
                    Toggle("从蒲公英自动获取", isOn: $viewModel.usePgyerBuildNumber)
                        .toggleStyle(.switch)
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
