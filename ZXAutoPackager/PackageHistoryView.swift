import AppKit
import SwiftUI

struct PackageHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: PackagerViewModel
    @State private var qrCodeURL: QRCodeURL?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("打包历史")
                    .font(.title2.bold())
                Spacer()
                Text("\(viewModel.packageHistory.count) 条记录")
                    .foregroundStyle(.secondary)
                Button("关闭") { dismiss() }
            }
            .padding(20)
            Divider()

            if let error = viewModel.historyError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
            }

            if viewModel.packageHistory.isEmpty {
                ContentUnavailableView(
                    "暂无打包历史",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("打包成功后会自动保存到这里")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.packageHistory) { record in
                            recordCard(record)
                        }
                    }
                    .padding(20)
                }
            }
        }
        .frame(minWidth: 660, minHeight: 460)
        .sheet(item: $qrCodeURL) { item in
            PgyerQRCodeView(downloadURL: item.value) {
                if let url = URL(string: item.value) { NSWorkspace.shared.open(url) }
            }
        }
    }

    private func recordCard(_ record: PackageHistoryRecord) -> some View {
        let fileExists = FileManager.default.fileExists(atPath: record.artifactPath)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.fileName)
                    .font(.headline)
                    .lineLimit(1)
                    .help(record.artifactPath)
                Spacer()
                Text(record.completedAt, format: .dateTime.year().month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Label(record.fileSizeText, systemImage: "internaldrive")
                Text("v\(record.version)")
                Text("Build \(record.buildNumber)")
                Text(record.configuration)
                Label("耗时 \(record.durationText)", systemImage: "clock")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)

            HStack {
                Text("\(record.scheme) · \(record.platform)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !fileExists {
                    Label("本地文件已不存在", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let downloadURL = record.downloadURL,
                   let url = URL(string: downloadURL),
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    Button("查看二维码") { qrCodeURL = QRCodeURL(value: downloadURL) }
                    Button("打开下载页面") { NSWorkspace.shared.open(url) }
                }
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.artifactPath)])
                }
                .disabled(!fileExists)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct QRCodeURL: Identifiable {
    let id = UUID()
    let value: String
}
