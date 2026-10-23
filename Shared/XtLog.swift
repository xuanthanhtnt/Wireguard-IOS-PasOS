// SPDX-License-Identifier: MIT
// WG VPN for iOS / iPadOS

import Foundation
import os

/// Small log shared by the app and the extension (one text file in the app group, rotated at 1 MB).
enum XtLog {
    static let tag: String = Bundle.main.bundleURL.pathExtension == "appex" ? "NET" : "APP"

    private static let queue = DispatchQueue(label: "com.wgvpn.log")
    private static let osLog = Logger(subsystem: "com.wgvpn", category: tag)
    private static let maxBytes = 1_000_000

    static var fileURL: URL { AppGroup.containerURL.appendingPathComponent("wgvpn.log") }
    static var oldFileURL: URL { AppGroup.containerURL.appendingPathComponent("wgvpn.log.1") }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String) { write("I", message) }
    static func error(_ message: String) { write("E", message) }
    static func debug(_ message: String) { write("D", message) }

    private static func write(_ level: String, _ message: String) {
        if level == "E" {
            osLog.error("\(message, privacy: .public)")
        } else {
            osLog.info("\(message, privacy: .public)")
        }
        let now = Date()
        queue.async {
            let line = "\(formatter.string(from: now)) [\(tag)] \(level) \(message)\n"
            let path = fileURL.path
            if let attributes = try? FileManager.default.attributesOfItem(atPath: path),
               let size = attributes[.size] as? NSNumber, size.intValue > maxBytes {
                try? FileManager.default.removeItem(at: oldFileURL)
                try? FileManager.default.moveItem(at: fileURL, to: oldFileURL)
            }
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            line.withCString { pointer in
                _ = Darwin.write(fd, pointer, strlen(pointer))
            }
            close(fd)
        }
    }

    /// Whole log (previous file first), newest lines last.
    static func readAll() -> String {
        let old = (try? String(contentsOf: oldFileURL, encoding: .utf8)) ?? ""
        let current = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        return old + current
    }

    static func clear() {
        queue.sync {
            try? FileManager.default.removeItem(at: oldFileURL)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }
}
