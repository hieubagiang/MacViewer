#if DEBUG
import AppKit
import SwiftUI
import UltraViewerProtocol

/// Debug-build window that shows ConnectLog live.
@MainActor
final class DebugLogWindowController {
    static let shared = DebugLogWindowController()
    private var window: NSWindow?

    private func makeWindow() -> NSWindow {
        if let window { return window }
        let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 520),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable],
                               backing: .buffered, defer: false)
        created.title = "MacViewer Connection Log (debug)"
        created.isReleasedWhenClosed = false
        created.contentView = NSHostingView(rootView: DebugLogView())
        created.setFrameAutosaveName("MacViewer.debugLogWindow")
        created.center()
        window = created
        return created
    }

    func show() { let w = makeWindow(); w.makeKeyAndOrderFront(nil) }
}

private struct DebugLogView: View {
    @State private var text = ConnectLog.snapshot()
    @State private var follow = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Copy all") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Clear") { ConnectLog.clear() }
                Button("Reveal file") { NSWorkspace.shared.activateFileViewerSelecting([ConnectLog.fileURL]) }
                Toggle("Follow", isOn: $follow)
                Spacer()
                Text(ConnectLog.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(8)
            Divider()
            LogTextView(text: text, follow: follow)
        }
        .onReceive(NotificationCenter.default.publisher(for: ConnectLog.didChange)) { _ in
            text = ConnectLog.snapshot()
        }
    }
}

private struct LogTextView: NSViewRepresentable {
    let text: String
    let follow: Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        if let view = scroll.documentView as? NSTextView {
            view.isEditable = false
            view.isSelectable = true
            view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            view.textContainerInset = NSSize(width: 6, height: 6)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
        if follow { view.scrollToEndOfDocument(nil) }
    }
}
#endif
