// ConfigStore.swift
// Config library management: scanning, importing, seeding and deleting.

import Foundation

public final class ConfigStore: @unchecked Sendable {
    public static let shared = ConfigStore()
    public static let defaultConfigFileName = "MSI-Vector-16-HX-A14VHG.xml"

    private let lock = NSLock()
    private var cached: [ConfigSummary] = []

    public init() {}

    public var summaries: [ConfigSummary] {
        lock.lock()
        defer { lock.unlock() }
        return cached
    }

    public func refresh() {
        AppPaths.ensureDirectories()
        var results: [ConfigSummary] = []
        var seen = Set<String>()

        func addDirectory(_ directory: URL, builtin: Bool) {
            let fm = FileManager.default
            guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                           includingPropertiesForKeys: [.isDirectoryKey],
                                                           options: [.skipsHiddenFiles]) else { return }
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDirectory {
                    if entry.lastPathComponent != "Generic" { continue }
                    addDirectory(entry, builtin: builtin)
                    continue
                }
                guard entry.pathExtension.lowercased() == "xml", seen.insert(entry.path).inserted else { continue }
                results.append(summary(for: entry, builtin: builtin))
            }
        }

        addDirectory(AppPaths.configsDirectory, builtin: false)

        // A broken user copy must not hide the bundled fallback.
        let userFileNames = Set(results.filter { $0.parseError == nil }.map { $0.path.lastPathComponent })
        for directory in AppPaths.bundledConfigDirectories() {
            let before = results.count
            addDirectory(directory, builtin: true)
            if results.count > before {
                results.removeAll { entry in
                    entry.isBuiltin && userFileNames.contains(entry.path.lastPathComponent)
                }
            }
        }

        lock.lock()
        cached = results
        lock.unlock()
    }

    private func summary(for url: URL, builtin: Bool) -> ConfigSummary {
        do {
            let config = try ConfigCodec.load(from: url)
            return ConfigSummary(path: url,
                                 manufacturer: config.layout.manufacturer,
                                 model: config.layout.model,
                                 author: config.layout.author,
                                 version: config.version,
                                 fanCount: config.fanCount,
                                 isBuiltin: builtin,
                                 parseError: nil)
        } catch {
            return ConfigSummary(path: url,
                                 manufacturer: url.deletingPathExtension().lastPathComponent,
                                 model: "",
                                 author: "",
                                 version: 0,
                                 fanCount: 0,
                                 isBuiltin: builtin,
                                 parseError: error.localizedDescription)
        }
    }

    public func load(_ summary: ConfigSummary) throws -> YamdccConfig {
        try ConfigCodec.load(from: summary.path)
    }

    public func load(url: URL) throws -> YamdccConfig {
        try ConfigCodec.load(from: url)
    }

    /// Honor a saved selection first. Otherwise prefer the Vector 16 HX template,
    /// not the first XML filename in the library.
    public func loadPreferred(activePath: String?) -> YamdccConfig? {
        if let activePath, let config = try? load(url: URL(fileURLWithPath: activePath)) {
            return config
        }
        let available = summaries.filter { $0.parseError == nil }
        for summary in available where summary.path.lastPathComponent == Self.defaultConfigFileName {
            if let config = try? load(summary) { return config }
        }
        for directory in AppPaths.bundledConfigDirectories() {
            if let config = try? load(url: directory.appendingPathComponent(Self.defaultConfigFileName)) {
                return config
            }
        }
        for summary in available {
            if let config = try? load(summary) { return config }
        }
        return nil
    }

    /// Copies every bundled config into the user library the first time the app runs.
    public func seedLibraryIfNeeded() {
        AppPaths.ensureDirectories()
        let existing = (try? FileManager.default.contentsOfDirectory(atPath: AppPaths.configsDirectory.path))?
            .filter { $0.hasSuffix(".xml") } ?? []
        guard existing.isEmpty else { return }
        for directory in AppPaths.bundledConfigDirectories() {
            importAllBundled(from: directory)
            return
        }
    }

    public func importAllBundled(from directory: URL) {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                        includingPropertiesForKeys: nil,
                                                                        options: [.skipsHiddenFiles]) else { return }
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if entry.pathExtension.lowercased() == "xml" {
                _ = try? importConfig(from: entry)
            } else if entry.lastPathComponent == "Generic" {
                importAllBundled(from: entry)
            }
        }
    }

    @discardableResult
    public func importConfig(from url: URL) throws -> URL {
        AppPaths.ensureDirectories()
        let fm = FileManager.default
        var destination = AppPaths.configsDirectory.appendingPathComponent(url.lastPathComponent)
        var counter = 2
        while fm.fileExists(atPath: destination.path) {
            let base = url.deletingPathExtension().lastPathComponent
            destination = AppPaths.configsDirectory
                .appendingPathComponent("\(base)-\(counter).xml")
            counter += 1
        }
        try fm.copyItem(at: url, to: destination)
        refresh()
        return destination
    }

    public func delete(_ summary: ConfigSummary) throws {
        guard !summary.isBuiltin else { return }
        try FileManager.default.removeItem(at: summary.path)
        refresh()
    }
}
