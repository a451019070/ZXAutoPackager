import AppKit
import SwiftUI

struct PackageHeaderView: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 3) {
                Text("ZX Auto Packager")
                    .font(.title2.bold())
                Text("选择 Xcode 工程，归档并导出 iOS 或 macOS 应用")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }
}
