// Paths.swift
// Filesystem locations used by the app and CLI.

import Foundation

public enum AppPaths {
    public static let appFolderName = "YAMDCC"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(appFolderName, isDirectory: true)
    }

    public static var configsDirectory: URL {
        supportDirectory.appendingPathComponent("Configs", isDirectory: true)
    }

    public static var logsDirectory: URL {
        supportDirectory.appendingPathComponent("Logs", isDirectory: true)
    }

    public static var settingsFile: URL {
        supportDirectory.appendingPathComponent("settings.json")
    }

    public static var logFile: URL {
        logsDirectory.appendingPathComponent("yamdcc.log")
    }

    @discardableResult
    public static func ensureDirectories() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: configsDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// Locations that may contain the configs shipped with the app.
    public static func bundledConfigDirectories() -> [URL] {
        var candidates: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("Configs", isDirectory: true))
        }
        candidates.append(Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/Configs", isDirectory: true))

        // Development: the executable lives in .build/<config>/YAMDCCApp.
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
        if !executable.path.isEmpty {
            var dir = executable.deletingLastPathComponent()
            for _ in 0..<5 {
                candidates.append(dir.appendingPathComponent("Resources/Configs", isDirectory: true))
                candidates.append(dir.appendingPathComponent("Configs", isDirectory: true))
                dir = dir.deletingLastPathComponent()
            }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Resources/Configs", isDirectory: true))
        candidates.append(cwd.appendingPathComponent("Configs", isDirectory: true))

        var seen = Set<String>()
        return candidates.filter { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue, seen.insert(url.path).inserted else { return false }
            return true
        }
    }

    public static var preferredBundledConfigDirectory: URL? {
        bundledConfigDirectories().first
    }
}
