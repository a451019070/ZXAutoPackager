import AppKit
import SwiftUI

struct PackageLogView: View {
    @AppStorage("ZXAutoPackager.progressViewHeight") private var storedHeight = 260.0
    @GestureState private var dragOffset = 0.0

    let log: String

    private var currentHeight: CGFloat {
        min(max(storedHeight + dragOffset, 140), 700)
    }

    var body: some View {
        GroupBox {
            VStack(spacing: 0) {
                BuildLogTextView(text: log.isEmpty ? "构建进度将在这里显示。" : log)
                    .frame(height: currentHeight)

                resizeHandle
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } label: {
            Label("构建进度", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.headline)
        }
    }

    private var resizeHandle: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .controlBackgroundColor))

            Capsule()
                .fill(.secondary.opacity(0.55))
                .frame(width: 42, height: 4)
        }
        .frame(height: 14)
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .updating($dragOffset) { value, state, _ in
                    state = value.translation.height
                }
                .onEnded { value in
                    storedHeight = min(max(storedHeight + value.translation.height, 140), 700)
                }
        )
        .help("上下拖动调整构建进度区域高度")
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
