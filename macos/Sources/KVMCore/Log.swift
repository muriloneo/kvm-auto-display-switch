import Foundation

/// Timestamped structured log lines: `[09:32:14.112] event key=value`.
public final class Log {
    public static let shared = Log()

    public var verbose = false
    /// Extra sink (the menu-bar app appends to ~/Library/Logs/KVMSwitcher.log).
    public var fileURL: URL?

    private let lock = NSLock()
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    public func info(_ message: String) { write(message, force: true) }
    public func debug(_ message: String) { write(message, force: verbose) }
    public func error(_ message: String) { write("ERROR " + message, force: true) }

    private func write(_ message: String, force: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(formatter.string(from: Date()))] \(message)\n"
        if force { FileHandle.standardError.write(Data(line.utf8)) }
        guard let url = fileURL else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}
