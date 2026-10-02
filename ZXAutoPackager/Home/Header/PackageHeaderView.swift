import AppKit
import SwiftUI

struct PackageHeaderView: View {
    @AppStorage("ZXAutoPackager.language") private var language = AppLanguage.system.rawValue
    @Binding var isShowingHistory: Bool
    
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
            
            Picker("语言", selection: $language) {
                Text("跟随系统").tag(AppLanguage.system.rawValue)
                Text("简体中文").tag(AppLanguage.chinese.rawValue)
                Text("英语").tag(AppLanguage.english.rawValue)
            }
            .fixedSize()
            Button {
                isShowingHistory = true
            } label: {
                Label("打包历史", systemImage: "clock.arrow.circlepath")
            }
            .padding(.trailing, 24)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }
}
