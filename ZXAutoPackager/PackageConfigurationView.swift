import SwiftUI

struct PackageConfigurationView: View {
    @ObservedObject var viewModel: PackagerViewModel

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
                    fieldTitle("构建环境")
                    Picker("构建环境", selection: $viewModel.configuration) {
                        ForEach(PackagerViewModel.Configuration.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }

                GridRow {
                    fieldTitle("版本号")
                    HStack {
                        TextField("例如：1.0.0", text: $viewModel.versionNumber)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)
                        Text("对应 Xcode 的 Version")
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
                        Text("成功后自动保存，下次默认 +1")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
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
                    fieldTitle("蒲公英")
                    Toggle("打包成功后自动上传", isOn: $viewModel.uploadToPgyer)
                        .toggleStyle(.switch)
                }

                if viewModel.uploadToPgyer {
                    GridRow {
                        fieldTitle("API Key")
                        SecureField("蒲公英 API Key", text: $viewModel.pgyerAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }

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
