import Foundation

/// A plain text log on this Mac, so that when something breaks there is a record of what happened.
/// One line per event: `2026-11-23 11:28:05 ERROR sonos speaker 2 Pause failed: no answer (timed out)`.
///
/// Contains no personal data: no IP addresses, device names or ids, room names, song titles or accounts.
/// Speakers are told apart by anonymous per-run labels ("speaker 2"). Callers must not put such data in a message.
/// Writing can never fail loudly: if the file can't be written, the line is dropped.
public final class Log: @unchecked Sendable {
    /// The app's real log: ~/Library/Logs/MacSonosControl/MacSonosControl.log.
    /// Detailed tracing of every request is off unless the app is started with `--verbose` or
    /// `defaults write com.lindewhat.mac-sonos-control verboseLog -bool true` is set.
    public static let shared = Log(
        fileURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/MacSonosControl/MacSonosControl.log"),
        verbose: CommandLine.arguments.contains("--verbose") || UserDefaults.standard.bool(forKey: "verboseLog"))

    public let fileURL: URL
    public let verbose: Bool
    private let maxBytes: Int
    private let lock = NSLock()

    public init(fileURL: URL, maxBytes: Int = 1_000_000, verbose: Bool = false) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.verbose = verbose
    }

    public func error(_ area: String, _ text: String) { write("ERROR", area, text) }
    public func warn(_ area: String, _ text: String) { write("WARN", area, text) }
    public func info(_ area: String, _ text: String) { write("INFO", area, text) }
    /// A trace of routine events (every request). Only written in verbose mode.
    public func trace(_ area: String, _ text: String) { if verbose { write("TRACE", area, text) } }

    static func line(_ level: String, _ area: String, _ text: String, at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let oneLine = text.replacingOccurrences(of: "\n", with: " ")
        return "\(f.string(from: date)) \(level) \(area) \(oneLine)\n"
    }

    private func write(_ level: String, _ area: String, _ text: String) {
        let data = Data(Self.line(level, area, text, at: Date()).utf8)
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Keep the file small: past the limit, the current file becomes the single older copy.
            if let size = (try? fm.attributesOfItem(atPath: fileURL.path))?[.size] as? Int, size > maxBytes {
                let older = fileURL.appendingPathExtension("1")
                try? fm.removeItem(at: older)
                try fm.moveItem(at: fileURL, to: older)
            }
            if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            // Logging must never get in the way of the app.
        }
    }
}
