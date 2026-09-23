import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

struct PgyerQRCodeView: View {
    @Environment(\.dismiss) private var dismiss

    let downloadURL: String
    let openPage: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("蒲公英下载二维码")
                    .font(.title2.bold())
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }

            if let image = makeQRCode(from: downloadURL) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 260, height: 260)
                    .padding(14)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                    .contextMenu {
                        Button("复制二维码图片") {
                            copyImage(image)
                        }
                    }

                Button {
                    copyImage(image)
                } label: {
                    Label("复制二维码图片", systemImage: "doc.on.doc")
                }
            } else {
                ContentUnavailableView(
                    "二维码生成失败",
                    systemImage: "qrcode",
                    description: Text(downloadURL)
                )
            }

            Text(downloadURL)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .multilineTextAlignment(.center)

            HStack {
                Button("关闭") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("在浏览器中打开", action: openPage)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 380)
    }

    private func copyImage(_ image: NSImage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
    }

    private func makeQRCode(from text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let scaledImage = outputImage.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let representation = NSCIImageRep(ciImage: scaledImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
