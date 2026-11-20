// Settings.swift
// Persisted UI/behaviour preferences.

import Foundation

public struct AppSettings: Codable, Equatable, Sendable {
    /// Path of the config that should be active on launch.
    public var activeConfigPath: String?
    public var forceSimulation: Bool = false
    public var pollInterval: Double = 1.0
    public var applyOnLaunch: Bool = true
    public var showMenuBarExtra: Bool = true
    public var hasSeenWelcome: Bool = false

    // Last UI selections, mirrored into the config when applying.
    public var lastProfiles: [Int] = []
    public var perfMode: Int = -1
    public var fanMode: Int = 3
    public var chargeLimitEnabled: Bool = false
    public var chargeLimit: Int = 80
    public var keyLight: Int = 0
    public var keySwap: Bool = false
    public var fullBlast: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeConfigPath = try container.decodeIfPresent(String.self, forKey: .activeConfigPath)
        forceSimulation = try container.decodeIfPresent(Bool.self, forKey: .forceSimulation) ?? false
        pollInterval = try container.decodeIfPresent(Double.self, forKey: .pollInterval) ?? 1.0
        applyOnLaunch = try container.decodeIfPresent(Bool.self, forKey: .applyOnLaunch) ?? true
        showMenuBarExtra = try container.decodeIfPresent(Bool.self, forKey: .showMenuBarExtra) ?? true
        hasSeenWelcome = try container.decodeIfPresent(Bool.self, forKey: .hasSeenWelcome) ?? false
        lastProfiles = try container.decodeIfPresent([Int].self, forKey: .lastProfiles) ?? []
        perfMode = try container.decodeIfPresent(Int.self, forKey: .perfMode) ?? -1
        fanMode = try container.decodeIfPresent(Int.self, forKey: .fanMode) ?? 3
        chargeLimitEnabled = try container.decodeIfPresent(Bool.self, forKey: .chargeLimitEnabled) ?? false
        chargeLimit = try container.decodeIfPresent(Int.self, forKey: .chargeLimit) ?? 80
        keyLight = try container.decodeIfPresent(Int.self, forKey: .keyLight) ?? 0
        keySwap = try container.decodeIfPresent(Bool.self, forKey: .keySwap) ?? false
        fullBlast = try container.decodeIfPresent(Bool.self, forKey: .fullBlast) ?? false
    }
}

public final class SettingsStore {
    public static let shared = SettingsStore()

    private let lock = NSLock()
    private var cached: AppSettings?

    public init() {}

    public var settings: AppSettings {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let value = Self.read()
        cached = value
        return value
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        lock.lock()
        var value = cached ?? Self.read()
        mutate(&value)
        cached = value
        lock.unlock()
        write(value)
    }

    public func replace(with value: AppSettings) {
        lock.lock()
        cached = value
        lock.unlock()
        write(value)
    }

    private static func read() -> AppSettings {
        guard let data = try? Data(contentsOf: AppPaths.settingsFile),
              let value = try? JSONDecoder().decode(AppSettings.self, from: data) else {
            return AppSettings()
        }
        return value
    }

    private func write(_ value: AppSettings) {
        AppPaths.ensureDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: AppPaths.settingsFile, options: .atomic)
    }
}
