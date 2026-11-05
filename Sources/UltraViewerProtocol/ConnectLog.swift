import Foundation
import OSLog

/// Connection diagnostics, active in debug builds only. Lines are kept in
/// memory for the in-app log window, appended to
/// ~/Library/Logs/MacViewer/connect.log and mirrored to unified logging.
/// Never logs passwords or payload bytes.
public enum ConnectLog {
    public static let fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/MacViewer/connect.log")
    /// Posted on the main queue after the log changes.
    public static let didChange = Notification.Name("dev.macviewer.connectlog.didChange")

    public static var isEnabled: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private final class Store: @unchecked Sendable {
        let lock = NSLock()
        var lines: [String] = []
    }

    private static let store = Store()
    private static let queue = DispatchQueue(label: "dev.macviewer.connectlog")
    private static let logger = Logger(subsystem: "dev.macviewer.app", category: "connect")
    private static let maximumBytes: UInt64 = 2_000_000
    private static let maximumLines = 3000

    public static func snapshot() -> String {
        store.lock.lock(); defer { store.lock.unlock() }
        return store.lines.joined(separator: "\n")
    }

    /// Clears the on-screen log; the file on disk is kept.
    public static func clear() {
        store.lock.lock(); store.lines.removeAll(); store.lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
    }

    public static func write(_ message: String) {
        #if DEBUG
        let stamp = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(formatter.string(from: stamp)) \(message)"
        logger.notice("\(message, privacy: .public)")
        store.lock.lock()
        store.lines.append(line)
        if store.lines.count > maximumLines { store.lines.removeFirst(store.lines.count - maximumLines) }
        store.lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: didChange, object: nil) }
        queue.async {
            let manager = FileManager.default
            let directory = fileURL.deletingLastPathComponent()
            try? manager.createDirectory(at: directory, withIntermediateDirectories: true)
            // Keep one previous file so the log cannot grow without bound.
            if let size = (try? manager.attributesOfItem(atPath: fileURL.path))?[.size] as? UInt64,
               size > maximumBytes {
                let old = directory.appendingPathComponent("connect.log.1")
                try? manager.removeItem(at: old)
                try? manager.moveItem(at: fileURL, to: old)
            }
            if !manager.fileExists(atPath: fileURL.path) {
                manager.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
        #endif
    }
}
