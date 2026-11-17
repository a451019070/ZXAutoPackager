import SwiftUI

struct PackageStatusView: View {
    @ObservedObject var viewModel: PackagerViewModel

    @AppStorage("statusMessageHeight") private var messageHeight: Double = 36
    @State private var dragStartHeight: Double?

    @State private var frozenMessage: String?

    private var currentMessage: String {
        viewModel.statusMessage == "请选择工程和导出目录" || viewModel.statusMessage == "已恢复上次填写的打包配置"
            ? viewModel.configurationHint : viewModel.statusMessage
    }

    private var mainMessage: String {
        viewModel.isShowingAdvancedOptions ? (frozenMessage ?? currentMessage) : currentMessage
    }

    private let minMessageHeight: Double = 36
    private let maxMessageHeight: Double = 500

    var body: some View {
        VStack(spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    statusContent
                        .frame(width: 300, alignment: .leading)
                    Spacer(minLength: 8)
                    actionButtons
                }

                VStack(alignment: .leading, spacing: 14) {
                    statusContent
                    HStack {
                        Spacer(minLength: 0)
                        actionButtons
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            resizeHandle
        }
        .padding(.top, 18)
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onChange(of: viewModel.isShowingAdvancedOptions) { _, showing in
            frozenMessage = showing ? currentMessage : nil
        }
    }

    private var resizeHandle: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 40, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 12)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartHeight ?? messageHeight
                        dragStartHeight = start
                        messageHeight = min(max(start + value.translation.height, minMessageHeight), maxMessageHeight)
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            .help("上下拖动调整状态区域高度")
    }

    private var statusContent: some View {
        HStack(alignment: .top, spacing: 14) {
            statusIcon
            VStack(alignment: .leading, spacing: 3) {
                ScrollView(.vertical) {
                    SelectableText(text: AppStrings.text(mainMessage))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: messageHeight)
                if viewModel.isPreparing {
                    Text("正在准备临时 Worktree…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if viewModel.isPackaging {
                    Text("进程运行中 · 已用时 \(viewModel.elapsedTimeText)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if let summary = viewModel.packageSummary {
                    ViewThatFits(in: .horizontal) {
                        summaryDetails(summary)
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 8) {
                                Label(summary.fileSize, systemImage: "internaldrive")
                                Text("v\(summary.version)")
                            }
                            HStack(spacing: 8) {
                                Text("Build \(summary.buildNumber)")
                                Text(summary.configuration)
                                Label("耗时 \(viewModel.elapsedTimeText)", systemImage: "clock")
                            }
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .help(summary.fileName)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summaryDetails(_ summary: PackageSummary) -> some View {
        HStack(spacing: 8) {
            Label(summary.fileSize, systemImage: "internaldrive")
            Text("v\(summary.version)")
            Text("Build \(summary.buildNumber)")
            Text(summary.configuration)
            Label("耗时 \(viewModel.elapsedTimeText)", systemImage: "clock")
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            if viewModel.pgyerDownloadURL != nil {
                Button("查看二维码", action: viewModel.showPgyerQRCode)
                Button("打开下载页面", action: viewModel.openPgyerDownloadPage)
            }

            if viewModel.lastArtifactPath != nil {
                Button("在 Finder 中显示", action: viewModel.revealArtifact)
            }

            if viewModel.isPackaging {
                Button(role: .destructive, action: viewModel.stopPackaging) {
                    Label("停止打包", systemImage: "stop.fill")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
            } else {
                Button(action: viewModel.startPackaging) {
                    Label("开始打包", systemImage: "hammer.fill")
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canPackage)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if viewModel.isPackaging || viewModel.isPreparing {
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
