import SwiftUI

struct PackageHeaderView: View {
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 28))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(.blue.gradient, in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 3) {
                Text("ZX Auto Packager")
                    .font(.title2.bold())
                Text("选择 iOS 工程，一键归档并导出 IPA")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
    }
}
