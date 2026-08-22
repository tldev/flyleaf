import Foundation
import os

enum LogCategory: String {
    case app, kindle, packs, panel, poller, auth, anthropic, wiki, stats
}

enum LogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warn = "WARN"
    case error = "ERROR"
}

// Logs go to both the unified log and a plain text file so the first
// on-device test can be debugged without attaching Console.app filters.
final class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()

    private let queue = DispatchQueue(label: "flyleaf.log", qos: .utility)
    private let maxBytes: UInt64 = 2_000_000
    let logURL: URL

    private init() {
        let dir = AppPaths.supportDir.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        logURL = dir.appendingPathComponent("flyleaf.log")
    }

    func append(_ line: String) {
        queue.async {
            let stamped = "\(Self.timestamp()) \(line)\n"
            guard let data = stamped.data(using: .utf8) else { return }
            let fm = FileManager.default
            if let attrs = try? fm.attributesOfItem(atPath: self.logURL.path),
               let size = attrs[.size] as? UInt64, size > self.maxBytes {
                let old = self.logURL.deletingLastPathComponent().appendingPathComponent("flyleaf.old.log")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: self.logURL, to: old)
            }
            if let handle = try? FileHandle(forWritingTo: self.logURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: self.logURL)
            }
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }
}

private let osLoggers: [LogCategory: Logger] = {
    var map = [LogCategory: Logger]()
    for c in [LogCategory.app, .kindle, .packs, .panel, .poller, .auth, .anthropic, .wiki, .stats] {
        map[c] = Logger(subsystem: "com.thomasjohnell.flyleaf", category: c.rawValue)
    }
    return map
}()

func log(_ category: LogCategory, _ level: LogLevel, _ message: String) {
    let line = "[\(level.rawValue)] [\(category.rawValue)] \(message)"
    switch level {
    case .debug: osLoggers[category]?.debug("\(message, privacy: .public)")
    case .info: osLoggers[category]?.info("\(message, privacy: .public)")
    case .warn: osLoggers[category]?.warning("\(message, privacy: .public)")
    case .error: osLoggers[category]?.error("\(message, privacy: .public)")
    }
    FileLogger.shared.append(line)
}

func log(_ category: LogCategory, _ message: String) {
    log(category, .info, message)
}

enum AppPaths {
    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Flyleaf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let databaseURL = supportDir.appendingPathComponent("flyleaf.sqlite")
    static let exportsDir: URL = {
        let dir = supportDir.appendingPathComponent("exports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
