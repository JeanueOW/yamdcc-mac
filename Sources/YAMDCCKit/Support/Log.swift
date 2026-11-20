// Log.swift
// Lightweight in-memory + on-disk log shared by the app and the CLI.

import Foundation

public final class Log: @unchecked Sendable {
    public struct Entry: Identifiable, Sendable {
        public let id = UUID()
        public let date: Date
        public let level: Level
        public let message: String

        public var line: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return "[\(formatter.string(from: date))] \(level.rawValue.uppercased()) \(message)"
        }
    }

    public enum Level: String, Sendable {
        case debug, info, warn, error

        public var symbol: String {
            switch self {
            case .debug: return "ant"
            case .info: return "info.circle"
            case .warn: return "exclamationmark.triangle"
            case .error: return "xmark.octagon"
            }
        }
    }

    public static let shared = Log()

    private let lock = NSLock()
    private var storage: [Entry] = []
    private let maximumEntries = 1000
    private var fileHandle: FileHandle?

    /// Called on an arbitrary thread after a new entry was appended.
    public var onChange: (() -> Void)?

    public init() {
        AppPaths.ensureDirectories()
        try? FileManager.default.createDirectory(at: AppPaths.logsDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: AppPaths.logFile.path) {
            FileManager.default.createFile(atPath: AppPaths.logFile.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: AppPaths.logFile)
        fileHandle?.seekToEndOfFile()
    }

    deinit {
        try? fileHandle?.close()
    }

    public func log(_ level: Level, _ message: String) {
        let entry = Entry(date: Date(), level: level, message: message)
        lock.lock()
        storage.append(entry)
        if storage.count > maximumEntries {
            storage.removeFirst(storage.count - maximumEntries)
        }
        let handle = fileHandle
        lock.unlock()

        if let data = (entry.line + "\n").data(using: .utf8) {
            handle?.write(data)
        }
        #if DEBUG
        print(entry.line)
        #endif
        onChange?()
    }

    public func debug(_ message: String) { log(.debug, message) }
    public func info(_ message: String) { log(.info, message) }
    public func warn(_ message: String) { log(.warn, message) }
    public func error(_ message: String) { log(.error, message) }

    public var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    public func clear() {
        lock.lock()
        storage.removeAll()
        lock.unlock()
        try? fileHandle?.truncate(atOffset: 0)
        onChange?()
    }
}
