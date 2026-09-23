import AppKit
import SwiftUI

struct PackageLogView: View {
    let log: String

    var body: some View {
        GroupBox {
            BuildLogTextView(text: log.isEmpty ? "打包日志将在这里显示。" : log)
                .frame(height: 260)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } label: {
            Label("构建日志", systemImage: "terminal")
                .font(.headline)
        }
    }
}

private struct BuildLogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .bezelBorder

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindPanel = true
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .textColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView,
              textView.string != text else { return }

        let visibleRect = scrollView.contentView.documentVisibleRect
        let documentHeight = textView.bounds.height
        let wasNearBottom = visibleRect.maxY >= documentHeight - 30

        textView.string = text

        if wasNearBottom {
            textView.scrollToEndOfDocument(nil)
        }
    }
}
