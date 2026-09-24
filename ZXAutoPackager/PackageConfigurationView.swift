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
                    TextField("例如：MyApp", text: $viewModel.scheme)
                        .textFieldStyle(.roundedBorder)
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

                GridRow {
                    fieldTitle("蒲公英")
                    Toggle("打包后上传蒲公英", isOn: $viewModel.uploadToPgyer)
                        .toggleStyle(.switch)
                }

                if viewModel.uploadToPgyer || viewModel.usePgyerBuildNumber {
                    GridRow {
                        fieldTitle("API Key")
                        SecureField("蒲公英 API Key", text: $viewModel.pgyerAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if viewModel.usePgyerBuildNumber {
                    GridRow {
                        fieldTitle("App Key")
                        SecureField("蒲公英应用 App Key", text: $viewModel.pgyerAppKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                if viewModel.uploadToPgyer {
                    GridRow {
                        fieldTitle("更新说明")
                        TextField("可选，本次版本更新内容", text: $viewModel.updateDescription)
                            .textFieldStyle(.roundedBorder)
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
                    Button(viewModel.isLoadingPgyerBuildNumber ? "查询中…" : "查询蒲公英") {
                        viewModel.fetchNextBuildNumberFromPgyer()
                    }
                    .disabled(!viewModel.canFetchPgyerBuildNumber)
                    Text(viewModel.usePgyerBuildNumber
                         ? "打包前自动使用当前 Version 的远端最大值 +1"
                         : "留空时读取 Xcode 的 CURRENT_PROJECT_VERSION")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
            }

            GridRow {
                fieldTitle("Build 来源")
                Toggle("从蒲公英自动获取", isOn: $viewModel.usePgyerBuildNumber)
                    .toggleStyle(.switch)
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
