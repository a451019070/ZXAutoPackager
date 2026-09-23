import SwiftUI

struct PackageStatusView: View {
    @ObservedObject var viewModel: PackagerViewModel

    var body: some View {
        HStack(spacing: 14) {
            statusIcon

            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.statusMessage)
                    .lineLimit(2)
                if viewModel.isPackaging {
                    Text("进程运行中 · 已用时 \(viewModel.elapsedTimeText)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            if viewModel.pgyerDownloadURL != nil {
                Button("查看二维码", action: viewModel.showPgyerQRCode)
                Button("打开下载页面", action: viewModel.openPgyerDownloadPage)
            }

            if viewModel.lastArtifactPath != nil {
                Button("在 Finder 中显示", action: viewModel.revealArtifact)
            }

            Button(action: viewModel.startPackaging) {
                Label(
                    viewModel.isPackaging ? "正在打包" : "开始打包",
                    systemImage: "hammer.fill"
                )
                .frame(minWidth: 100)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canPackage)
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var statusIcon: some View {
        if viewModel.isPackaging {
            ProgressView()
                .controlSize(.small)
        } else {
            Image(
                systemName: viewModel.lastArtifactPath == nil
                    ? "info.circle.fill"
                    : "checkmark.circle.fill"
            )
            .foregroundStyle(
                viewModel.lastArtifactPath == nil ? Color.secondary : Color.green
            )
        }
    }
}
