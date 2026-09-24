import SwiftUI

struct PackageView: View {
    @StateObject private var viewModel = PackagerViewModel()

    var body: some View {
        VStack(spacing: 0) {
            PackageHeaderView()
            Divider()
            ScrollView {
                VStack(spacing: 18) {
                    PackageConfigurationView(viewModel: viewModel)
                    PackageStatusView(viewModel: viewModel)
                    if viewModel.isPackaging || !viewModel.log.isEmpty {
                        PackageLogView(log: viewModel.log)
                    } else {
                        Label("尚未开始打包，运行后将在这里显示构建进度", systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(24)
            }
        }
        .frame(minWidth: 720, minHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            if viewModel.useGitBranch && viewModel.remoteBranches.isEmpty {
                viewModel.refreshBranches(fetchRemote: false)
            }
        }
        .sheet(isPresented: $viewModel.isShowingQRCode) {
            if let downloadURL = viewModel.pgyerDownloadURL {
                PgyerQRCodeView(
                    downloadURL: downloadURL,
                    openPage: viewModel.openPgyerDownloadPage
                )
            }
        }
    }
}

#Preview {
    PackageView()
}
