// AppState.swift
// Central observable model shared by every view.

import Foundation
import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers
import YAMDCCKit

@MainActor
final class AppState: ObservableObject {

    enum Section: String, CaseIterable, Identifiable {
        case dashboard, fans, hardware, telemetry, inspector, configs, settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dashboard: return "总览"
            case .fans: return "风扇曲线"
            case .hardware: return "硬件设置"
            case .telemetry: return "真机采样"
            case .inspector: return "EC 监视器"
            case .configs: return "配置文件"
            case .settings: return "设置"
            }
        }

        var icon: String {
            switch self {
            case .dashboard: return "gauge.with.dots.needle.67percent"
            case .fans: return "wind"
            case .hardware: return "slider.horizontal.3"
            case .telemetry: return "waveform.path.ecg"
            case .inspector: return "cpu"
            case .configs: return "doc.text"
            case .settings: return "gearshape"
            }
        }
    }

    // MARK: Published state

    @Published var section: Section? = .dashboard
    @Published var config: YamdccConfig?
    @Published var summaries: [ConfigSummary] = []
    @Published var selectedTarget: FanTarget = .cpu
    /// Last non-advanced fan mode, restored when the switch is turned off.
    private var lastBasicFanMode: Int = 0
    @Published var backendInfo: ECInfo
    @Published var lastError: String?
    @Published var statusText = "就绪"
    @Published var isApplying = false
    @Published var monitor: Monitor?
    @Published private(set) var telemetrySample: ECTelemetrySample?

    // MARK: Dependencies

    let settings = SettingsStore.shared
    private(set) var transport: ECTransport?
    private(set) var controller: FanController?
    private var monitorCancellable: AnyCancellable?
    private var didAutoApply = false

    init() {
        backendInfo = ECInfo(backend: "未连接", isSimulated: true,
                             firmwareVersion: "", firmwareDate: "")
        reloadConfigs()
        connect()
        StatusItemController.shared.attach(state: self)
    }

    // MARK: Connection

    func connect() {
        monitor?.stop()
        transport?.close()

        let connection: (transport: ECTransport, info: ECInfo)?
        if settings.settings.forceSimulation {
            connection = ECBackend.simulated()
        } else {
            connection = ECBackend.connectRealOnly()
        }
        guard let (newTransport, info) = connection else {
            transport = nil
            controller = nil
            monitor = nil
            monitorCancellable = nil
            backendInfo = ECInfo(backend: "未连接", isSimulated: false,
                                 firmwareVersion: "", firmwareDate: "")
            if config == nil { config = loadInitialConfig() }
            statusText = "没有可用的 EC 驱动"
            return
        }
        transport = newTransport
        backendInfo = info

        if config == nil {
            config = loadInitialConfig()
        }

        guard let config else {
            statusText = "尚未载入配置"
            return
        }

        let controller = FanController(transport: newTransport, config: config)
        self.controller = controller

        let monitor = Monitor(controller: controller,
                              interval: settings.settings.pollInterval)
        self.monitor = monitor
        // Relay the monitor's published changes so views that only observe
        // AppState (dashboard, menu bar) refresh on every sample.
        monitorCancellable = monitor.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.objectWillChange.send() }
        }
        monitor.start()

        statusText = info.isSimulated ? "模拟模式" : "已连接 EC"
        Log.shared.info("AppState 已连接：\(info.backend)")

        if !didAutoApply, settings.settings.applyOnLaunch, !info.isSimulated {
            didAutoApply = true
            do {
                try controller.apply(config)
                monitor.pollNow()
                statusText = "已应用"
                Log.shared.info("启动时已自动应用配置")
            } catch {
                report(error, prefix: "启动自动应用失败")
            }
        }
    }

    private func loadInitialConfig() -> YamdccConfig? {
        let activePath = settings.settings.activeConfigPath
        let loaded = ConfigStore.shared.loadPreferred(activePath: activePath)
        if let path = loaded?.sourceURL?.path, path != activePath {
            settings.update { $0.activeConfigPath = path }
        }
        return loaded
    }

    func reloadConfigs() {
        ConfigStore.shared.seedLibraryIfNeeded()
        ConfigStore.shared.refresh()
        summaries = ConfigStore.shared.summaries
    }

    // MARK: Config lifecycle

    func loadConfig(_ summary: ConfigSummary) {
        do {
            let loaded = try ConfigCodec.load(from: summary.path)
            applyLoaded(loaded, path: summary.path)
            statusText = "已载入 \(loaded.displayName)"
        } catch {
            report(error, prefix: "无法载入配置")
        }
    }

    func loadConfig(url: URL) {
        do {
            let loaded = try ConfigCodec.load(from: url)
            applyLoaded(loaded, path: url)
            statusText = "已载入 \(loaded.displayName)"
        } catch {
            report(error, prefix: "无法载入配置")
        }
    }

    private func applyLoaded(_ loaded: YamdccConfig, path: URL) {
        var loaded = loaded
        normalizePerfModes(&loaded)
        reconcileProfiles(&loaded)
        config = loaded
        if !isAdvancedFanMode {
            lastBasicFanMode = fanModeIndex
        }
        controller?.updateConfig(loaded)
        settings.update { $0.activeConfigPath = path.path }
        syncTargets()
    }

    private func syncTargets() {
        guard let config else { return }
        if config.fans.count == 1 {
            selectedTarget = .cpu
        }
    }

    func saveConfig() {
        guard let config else { return }
        if let path = settings.settings.activeConfigPath {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let isBundled = AppPaths.bundledConfigDirectories().contains { directory in
                url.path.hasPrefix(directory.standardizedFileURL.path + "/")
            }
            if isBundled {
                saveConfigAs()
                return
            }
            do {
                try ConfigCodec.save(config, to: url)
                statusText = "已保存 \(url.lastPathComponent)"
                reloadConfigs()
            } catch {
                report(error, prefix: "保存失败")
            }
        } else {
            saveConfigAs()
        }
    }

    func saveConfigAs() {
        guard let config else { return }
        let directory = AppPaths.configsDirectory
        let base = "\(config.layout.manufacturer)-\(config.layout.model)"
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        var url = directory.appendingPathComponent("\(base).xml")
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(counter).xml")
            counter += 1
        }
        do {
            try ConfigCodec.save(config, to: url)
            settings.update { $0.activeConfigPath = url.path }
            reloadConfigs()
            statusText = "已另存为 \(url.lastPathComponent)"
        } catch {
            report(error, prefix: "保存失败")
        }
    }

    func deleteConfig(_ summary: ConfigSummary) {
        guard !summary.isBuiltin else {
            report(message: "内置配置不能删除")
            return
        }
        do {
            try ConfigStore.shared.delete(summary)
            if settings.settings.activeConfigPath == summary.path.path {
                settings.update { $0.activeConfigPath = nil }
            }
            reloadConfigs()
        } catch {
            report(error, prefix: "删除失败")
        }
    }

    func importConfig(url: URL) {
        do {
            let destination = try ConfigStore.shared.importConfig(from: url)
            reloadConfigs()
            if let summary = summaries.first(where: { $0.path == destination }) {
                loadConfig(summary)
            }
        } catch {
            report(error, prefix: "导入失败")
        }
    }

    // MARK: Offline telemetry

    func importTelemetry(from url: URL) {
        do {
            telemetrySample = try ECTelemetryCapture.load(from: url)
        } catch {
            report(error, prefix: "无法导入真机采样")
        }
    }

    func clearTelemetry() {
        telemetrySample = nil
    }

    // MARK: Apply

    func apply() {
        guard backendInfo.backend != "未连接" else {
            report(message: "没有可用的 EC 驱动（MSIEC 1.1.0 或显式模拟模式）")
            return
        }
        guard let controller, let config else { return }
        isApplying = true
        defer { isApplying = false }
        do {
            try controller.apply(config)
            if config.settings.chargeLimit == 0 {
                try? controller.applyChargeLimit(0)
            }
            try persistConfig()
            monitor?.pollNow()
            statusText = "已应用"
            Log.shared.info(statusText)
        } catch {
            report(error, prefix: "应用失败")
        }
    }

    /// Saves the current config, so reopening the app shows the same values
    /// instead of the stale on-disk ones.
    private func persistConfig() throws {
        guard let config else { return }
        let directory = AppPaths.configsDirectory.standardizedFileURL
        let active = settings.settings.activeConfigPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        let isInUserDirectory = active.map {
            $0.deletingLastPathComponent() == directory
        } ?? false

        let destination: URL
        if isInUserDirectory, let active {
            destination = active
        } else {
            let name = active?.lastPathComponent
                ?? "\(config.layout.manufacturer)-\(config.layout.model)"
                    .replacingOccurrences(of: " ", with: "-")
                    .appending(".xml")
            destination = directory.appendingPathComponent(name)
        }
        try ConfigCodec.save(config, to: destination)
        settings.update { $0.activeConfigPath = destination.path }
        ConfigStore.shared.refresh()
        summaries = ConfigStore.shared.summaries
    }

    func revertToHardware() {
        monitor?.pollNow()
        statusText = backendInfo.isSimulated ? "已刷新模拟状态" : "已刷新硬件状态"
    }

    /// Discards unsaved edits by reloading the active config from disk.
    func revertEdits() {
        guard let path = settings.settings.activeConfigPath else {
            statusText = "没有可还原的配置"
            return
        }
        do {
            let loaded = try ConfigCodec.load(from: URL(fileURLWithPath: path))
            config = loaded
            controller?.updateConfig(loaded)
            statusText = "已还原为 \(loaded.displayName)"
            monitor?.pollNow()
        } catch {
            report(error, prefix: "还原失败")
        }
    }

    // MARK: Pending edits (applied with Apply)

    func setPendingFullBlast(_ enabled: Bool) { updateSettings { $0.fullBlast = enabled } }

    func setPendingChargeLimit(_ percent: Int) {
        updateSettings { $0.chargeLimit = max(0, min(100, percent)) }
    }

    func setPendingPerfMode(_ index: Int) {
        updateSettings { $0.perfMode = index }
        autoSaveConfig()
    }

    /// Extras' 默认性能模式 / 风扇模式 are defaults rather than one-shot EC
    /// writes, so keep them on disk right away.
    private func autoSaveConfig() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            do {
                try self.persistConfig()
            } catch {
                Log.shared.error("自动保存配置失败: \(error.localizedDescription)")
            }
        }
    }

    func setPendingFanMode(_ index: Int) {
        if index != advancedFanModeIndex, fanModeOptions.indices.contains(index) {
            lastBasicFanMode = index
        }
        updateSettings { $0.fanMode = index }
        autoSaveConfig()
    }

    func setPendingKeyLight(_ percent: Int) {
        updateSettings { $0.keyLight = max(0, min(100, percent)) }
    }

    func setPendingKeySwap(_ enabled: Bool) { updateSettings { $0.keySwap = enabled } }

    // MARK: Panels

    func presentOpenConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选择 YAMDCC 配置文件"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadConfig(url: url)
    }

    func presentImportConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.xml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "导入到配置库"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importConfig(url: url)
    }

    // MARK: Hardware toggles (immediate writes)

    func setFullBlast(_ enabled: Bool) {
        guard let controller else { return }
        do {
            try controller.setFullBlast(enabled)
            updateSettings { $0.fullBlast = enabled }
            monitor?.pollNow()
        } catch {
            report(error, prefix: "设置全速失败")
        }
    }

    func setChargeLimit(enabled: Bool, percent: Int) {
        guard let controller else { return }
        do {
            try controller.applyChargeLimit(enabled ? percent : 0)
            updateSettings {
                $0.chargeLimit = enabled ? percent : 0
            }
            monitor?.pollNow()
        } catch {
            report(error, prefix: "设置充电上限失败")
        }
    }

    func setPerfMode(index: Int) {
        guard let controller else { return }
        do {
            try controller.setPerfMode(index: index)
            updateSettings { $0.perfMode = index }
            // Keep profiles in sync so the main window's per-profile picker
            // follows a menu bar switch instead of showing a stale value.
            setProfilePerfModeUnified(index)
            monitor?.pollNow()
        } catch {
            report(error, prefix: "设置性能模式失败")
        }
    }

    /// Reset every profile to "follow default" and apply that default mode.
    func setPerfModeFollowDefault() {
        guard let controller else { return }
        let index = defaultPerfModeIndex
        setProfilePerfModeUnified(-1)
        do {
            try controller.setPerfMode(index: index)
            monitor?.pollNow()
        } catch {
            report(error, prefix: "设置性能模式失败")
        }
    }

    func setFanMode(index: Int) {
        guard let controller else { return }
        do {
            try controller.setFanMode(index: index)
            updateSettings { $0.fanMode = index }
            autoSaveConfig()
            monitor?.pollNow()
        } catch {
            report(error, prefix: "设置风扇模式失败")
        }
    }

    func setKeyLight(_ percent: Int) {
        guard let controller else { return }
        do {
            try controller.setKeyLight(percent)
            updateSettings { $0.keyLight = percent }
            monitor?.pollNow()
        } catch {
            report(error, prefix: "设置背光失败")
        }
    }

    func setKeySwap(_ enabled: Bool) {
        guard let controller else { return }
        do {
            try controller.setKeySwap(enabled)
            updateSettings { $0.keySwap = enabled }
            monitor?.pollNow()
        } catch {
            report(error, prefix: "设置 Win/Fn 交换失败")
        }
    }

    private func updateSettings(_ body: (inout HardwareSettings) -> Void) {
        guard var config else { return }
        body(&config.settings)
        self.config = config
        controller?.updateConfig(config)
    }

    // MARK: Profile editing

    var currentLayout: DeviceLayout? { config?.layout }

    func profileSet(for target: FanTarget) -> FanProfileSet? {
        config?.profileSet(for: target)
    }

    func profile(for target: FanTarget) -> FanProfile? {
        config?.currentProfile(for: target)
    }

    /// Profile selection is shared by every fan: both fans expose the same
    /// profile list, so switching fans must not jump back to "Default".
    func selectProfile(_ index: Int, for target: FanTarget) {
        mutateConfig { config in
            guard target.rawValue < config.fans.count,
                  config.fans[target.rawValue].profiles.indices.contains(index) else { return }
            for fan in config.fans.indices where config.fans[fan].profiles.indices.contains(index) {
                config.fans[fan].selected = index
            }
        }
        if let config { controller?.updateConfig(config) }
    }

    func mutateProfile(for target: FanTarget, _ body: (inout FanProfile) -> Void) {
        mutateConfig { config in
            guard target.rawValue < config.fans.count else { return }
            let index = config.fans[target.rawValue].selected
            guard config.fans[target.rawValue].profiles.indices.contains(index) else { return }
            body(&config.fans[target.rawValue].profiles[index])
        }
        if let config { controller?.updateConfig(config) }
    }

    func setThreshold(target: FanTarget, index: Int,
                      up: Int? = nil, down: Int? = nil, speed: Int? = nil) {
        guard let layout = config?.layout,
              target.rawValue < layout.fans.count else { return }
        let fan = layout.fans[target.rawValue]
        mutateProfile(for: target) { profile in
            guard profile.thresholds.indices.contains(index) else { return }
            if let up {
                // Keep the curve monotonic: temperatures must strictly increase.
                let lower = index > 0 ? profile.thresholds[index - 1].up + 1 : 20
                let upper = index < profile.thresholds.count - 1
                    ? profile.thresholds[index + 1].up - 1 : 110
                let clamped = min(max(up, lower), max(lower, upper))
                profile.thresholds[index].up = clamped
                if profile.thresholds[index].down > clamped {
                    profile.thresholds[index].down = clamped
                }
            }
            if let down {
                profile.thresholds[index].down = min(max(down, 20), profile.thresholds[index].up)
            }
            if let speed {
                profile.thresholds[index].speed = min(max(speed, fan.minSpeed),
                                                      max(fan.minSpeed + 1, fan.maxSpeed))
            }
        }
    }

    func addProfile(for target: FanTarget) {
        guard let layout = config?.layout,
              target.rawValue < layout.fans.count else { return }
        let fan = layout.fans[target.rawValue]
        let base = profile(for: target) ?? FanProfile.defaultProfile(for: fan)
        let suggestion = "自定义 \((profileSet(for: target)?.profiles.count ?? 0) + 1)"
        guard let name = promptText(
            title: "新建配置档案",
            message: "为新档案输入名称（内容复制自「\(base.name)」）",
            initial: suggestion) else { return }
        mutateConfig { config in
            for fan in config.fans.indices {
                let template = config.fans[fan].current ?? base
                config.fans[fan].profiles.append(template.duplicated(name: name))
                config.fans[fan].selected = config.fans[fan].profiles.count - 1
            }
        }
        if let config { controller?.updateConfig(config) }
        autoSaveConfig()
        statusText = "已新建配置档案「\(name)」"
    }

    /// Renames the selected profile after asking for a new name.
    func renameProfileInteractively(for target: FanTarget) {
        guard let profile = profile(for: target) else { return }
        guard let name = promptText(
            title: "重命名配置档案",
            message: "输入新的档案名称",
            initial: profile.name), name != profile.name else { return }
        renameProfile(name, description: profile.desc, for: target)
        autoSaveConfig()
        statusText = "已重命名为「\(name)」"
    }

    /// Small `NSAlert`-based text prompt, mirroring the original editor's dialogs.
    func promptText(title: String, message: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = initial
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    func duplicateProfile(for target: FanTarget) {
        guard let profile = profile(for: target) else { return }
        let copy = profile.duplicated(name: profile.name + " 副本")
        mutateConfig { config in
            guard target.rawValue < config.fans.count else { return }
            config.fans[target.rawValue].profiles.append(copy)
            config.fans[target.rawValue].selected = config.fans[target.rawValue].profiles.count - 1
        }
        if let config { controller?.updateConfig(config) }
    }

    func deleteProfile(for target: FanTarget) {
        mutateConfig { config in
            guard target.rawValue < config.fans.count else { return }
            guard config.fans[target.rawValue].profiles.count > 1 else { return }
            let index = config.fans[target.rawValue].selected
            for fan in config.fans.indices {
                guard config.fans[fan].profiles.count > 1,
                      config.fans[fan].profiles.indices.contains(index) else { continue }
                config.fans[fan].profiles.remove(at: index)
                config.fans[fan].selected = max(0, index - 1)
            }
        }
        if let config { controller?.updateConfig(config) }
        autoSaveConfig()
    }

    /// Names and descriptions are shared by name across fans, so rename every
    /// fan's profile at the same position.
    func renameProfile(_ name: String, description: String, for target: FanTarget) {
        guard let index = profileSet(for: target)?.selected else { return }
        mutateConfig { config in
            for fan in config.fans.indices where config.fans[fan].profiles.indices.contains(index) {
                config.fans[fan].profiles[index].name = name
                config.fans[fan].profiles[index].desc = description
            }
        }
        if let config { controller?.updateConfig(config) }
    }

    func setProfilePerfMode(_ mode: Int, for target: FanTarget) {
        setProfilePerfModeUnified(mode)
    }

    // MARK: Performance mode (one value for the whole machine)

    var perfModeOptions: [EnumOption] {
        config?.layout.perfMode?.options ?? []
    }

    /// Per-profile performance mode. `-1` means "follow the default mode".
    /// CPU and GPU always carry the same value (the EC has one register).
    var profilePerfModeIndex: Int {
        guard let config else { return -1 }
        for set in config.fans {
            if let profile = set.current { return profile.perfMode }
        }
        return -1
    }

    /// The config-wide default used when a profile says "follow default".
    var defaultPerfModeIndex: Int {
        guard let config else { return 0 }
        let selected = config.settings.perfMode
        return selected >= 0 ? selected : (config.layout.perfMode?.defaultIndex ?? 0)
    }

    // MARK: Fan mode (advanced switch)

    var fanModeOptions: [EnumOption] {
        config?.layout.fanMode?.options ?? []
    }

    /// Index of the current fan mode, falling back to the layout default.
    var fanModeIndex: Int {
        guard let config else { return 0 }
        let selected = config.settings.fanMode
        return selected >= 0 ? selected : (config.layout.fanMode?.defaultIndex ?? 0)
    }

    /// "Advanced (default)" in YAMDCC configs: the EC follows the custom curve.
    var advancedFanModeIndex: Int? {
        fanModeOptions.firstIndex { $0.value == 0x8D }
            ?? fanModeOptions.firstIndex {
                $0.name.localizedCaseInsensitiveContains("advanced")
            }
    }

    var isAdvancedFanMode: Bool {
        guard let advanced = advancedFanModeIndex else { return false }
        return fanModeIndex == advanced
    }

    /// Turns the custom curve on (fan mode = Advanced) or off (fan mode = the
    /// last non-advanced choice, i.e. what "额外设置" selects).
    func setAdvancedFanMode(_ enabled: Bool) {
        guard let advanced = advancedFanModeIndex else { return }
        if enabled {
            setPendingFanMode(advanced)
        } else {
            setPendingFanMode(lastBasicFanMode)
        }
    }

    /// Applies to every profile of both fans, so switching fans/profiles shows
    /// the same value; `-1` keeps "follow default".
    func setProfilePerfModeUnified(_ index: Int) {
        mutateConfig { config in
            for fan in config.fans.indices {
                for profile in config.fans[fan].profiles.indices {
                    config.fans[fan].profiles[profile].perfMode = index
                }
            }
        }
        if let config { controller?.updateConfig(config) }
    }

    func setDefaultPerfMode(_ index: Int) {
        mutateConfig { $0.settings.perfMode = index }
        autoSaveConfig()
        if let config { controller?.updateConfig(config) }
    }

    /// Both fans must expose the same profiles (same names, same order) so that
    /// switching fans keeps the selected profile. Older edits could leave one
    /// fan with an extra profile; copy the missing ones across.
    private func reconcileProfiles(_ config: inout YamdccConfig) {
        guard let longest = config.fans.max(by: { $0.profiles.count < $1.profiles.count }),
              !longest.profiles.isEmpty else { return }
        let names = longest.profiles.map(\.name)

        for fan in config.fans.indices {
            let current = config.fans[fan]
            guard current.profiles != longest.profiles else { continue }
            let selectedName = current.profiles.indices.contains(current.selected)
                ? current.profiles[current.selected].name
                : names[0]

            var rebuilt: [FanProfile] = []
            for (index, name) in names.enumerated() {
                if let existing = current.profiles.first(where: { $0.name == name }) {
                    rebuilt.append(existing)
                } else if longest.profiles.indices.contains(index) {
                    let source = longest.profiles[index]
                    var copy = source.duplicated(name: name)
                    copy.desc = source.desc
                    rebuilt.append(copy)
                }
            }
            config.fans[fan].profiles = rebuilt
            config.fans[fan].selected = rebuilt.firstIndex { $0.name == selectedName } ?? 0
        }

        // The profile selection is shared too, so switching fans never shows
        // a different profile.
        if let first = config.fans.first.map({ min($0.selected, names.count - 1) }) {
            for fan in config.fans.indices {
                config.fans[fan].selected = first
            }
        }
    }

    private func normalizePerfModes(_ config: inout YamdccConfig) {
        guard config.layout.perfMode != nil else { return }
        // Keep whatever the first profile stores (including -1) and mirror it.
        let value = config.fans.first?.current?.perfMode ?? -1
        for fan in config.fans.indices {
            for profile in config.fans[fan].profiles.indices {
                config.fans[fan].profiles[profile].perfMode = value
            }
        }
    }

    func resetThresholds(for target: FanTarget) {
        guard let layout = config?.layout, target.rawValue < layout.fans.count else { return }
        let defaults = FanProfile.defaultProfile(for: layout.fans[target.rawValue])
        mutateProfile(for: target) { $0.thresholds = defaults.thresholds }
    }

    private func mutateConfig(_ body: (inout YamdccConfig) -> Void) {
        guard var config else { return }
        body(&config)
        self.config = config
    }

    // MARK: Diagnostics

    func report(_ error: Error, prefix: String) {
        let message = "\(prefix): \(error.localizedDescription)"
        lastError = message
        Log.shared.error(message)
        statusText = message
    }

    func report(message: String) {
        lastError = message
        statusText = message
    }

    var validationIssues: [String] {
        config?.validationProblems() ?? []
    }
}
