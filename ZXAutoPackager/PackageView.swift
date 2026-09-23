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
                    PackageLogView(log: viewModel.log)
                }
                .padding(24)
            }
        }
        .frame(minWidth: 720, minHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
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
