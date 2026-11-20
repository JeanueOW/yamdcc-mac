// YamdccConfig.swift
// Reading and writing YAMDCC configuration files (v1 legacy and v2).

import Foundation

public struct FanProfileSet: Codable, Equatable, Sendable {
    public var profiles: [FanProfile]
    public var selected: Int

    public init(profiles: [FanProfile], selected: Int = 0) {
        self.profiles = profiles
        self.selected = selected
    }

    public var current: FanProfile? {
        guard profiles.indices.contains(selected) else { return profiles.first }
        return profiles[selected]
    }

    public mutating func clampSelection() {
        if profiles.isEmpty {
            selected = 0
        } else {
            selected = max(0, min(selected, profiles.count - 1))
        }
    }
}

public struct YamdccConfig: Equatable, Sendable {
    public var version: Int
    public var layout: DeviceLayout
    public var fans: [FanProfileSet]
    public var settings: HardwareSettings
    public var sourceURL: URL?

    public init(version: Int, layout: DeviceLayout, fans: [FanProfileSet],
                settings: HardwareSettings, sourceURL: URL? = nil) {
        self.version = version
        self.layout = layout
        self.fans = fans
        self.settings = settings
        self.sourceURL = sourceURL
    }

    public var displayName: String { layout.displayName }

    public func profileSet(for target: FanTarget) -> FanProfileSet? {
        guard fans.indices.contains(target.rawValue) else { return nil }
        return fans[target.rawValue]
    }

    public func currentProfile(for target: FanTarget) -> FanProfile? {
        profileSet(for: target)?.current
    }

    public func selectedProfileIndex(for target: FanTarget) -> Int {
        profileSet(for: target)?.selected ?? 0
    }

    public var fanCount: Int { min(fans.count, layout.fans.count) }

    /// Non-fatal problems that would make this config impossible or unsafe to apply.
    public func validationProblems() -> [String] {
        var issues: [String] = []
        issues.append(contentsOf: layout.registerProblems)
        if fans.count != layout.fans.count {
            issues.append("风扇曲线数量（\(fans.count)）与寄存器布局（\(layout.fans.count)）不一致")
        }
        for (i, set) in fans.enumerated() {
            if set.profiles.isEmpty {
                issues.append("风扇 \(i + 1) 没有曲线")
                continue
            }
            if !set.profiles.indices.contains(set.selected) {
                issues.append("风扇 \(i + 1) 选中的曲线索引越界")
            }
            let minSpeed = layout.fans.indices.contains(i) ? layout.fans[i].minSpeed : 0
            let maxSpeed = layout.fans.indices.contains(i) ? layout.fans[i].maxSpeed : 100
            if let profile = set.current {
                if profile.thresholds.count != (layout.fans.indices.contains(i) ? layout.fans[i].curveRegs.count : profile.thresholds.count) {
                    issues.append("风扇 \(i + 1) 曲线点数与 EC 寄存器数量不一致")
                }
                issues.append(contentsOf: profile.problems(minSpeed: minSpeed, maxSpeed: maxSpeed)
                    .map { "风扇 \(i + 1)「\(profile.name)」: \($0)" })
            }
        }
        return issues
    }
}

// MARK: - Errors

public enum ConfigError: LocalizedError {
    case unsupportedVersion(Int)
    case missingElement(String)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "不支持的配置版本 \(version)（支持版本 1 和 2）"
        case .missingElement(let name):
            return "配置缺少必需的元素 <\(name)>"
        case .invalid(let message):
            return "配置无效：\(message)"
        }
    }
}

// MARK: - Codec

public enum ConfigCodec {

    public static func load(from url: URL) throws -> YamdccConfig {
        var config = try parse(contentsOf: url)
        config.sourceURL = url
        return config
    }

    public static func parse(contentsOf url: URL) throws -> YamdccConfig {
        let root = try XMLTree.parse(contentsOf: url)
        return try parse(root: root)
    }

    public static func parse(data: Data) throws -> YamdccConfig {
        let root = try XMLTree.parse(data: data)
        return try parse(root: root)
    }

    public static func parse(root: XMLNode) throws -> YamdccConfig {
        switch root.name {
        case "YAMDCC_Config":
            return try parseV1(root)
        case "YamdccCfg":
            return try parseV2(root)
        default:
            // Fall back to the version attribute if the root name is unexpected.
            let version = Int(root.attributes["Ver"] ?? "") ?? 0
            if version == 1 { return try parseV1(root) }
            if version == 2 { return try parseV2(root) }
            throw ConfigError.unsupportedVersion(version)
        }
    }

    // MARK: Version 1 (legacy register configs)

    private static func parseV1(_ root: XMLNode) throws -> YamdccConfig {
        let fanNodes = root.child("FanConfs")?.children("FanConf") ?? []
        guard !fanNodes.isEmpty else { throw ConfigError.missingElement("FanConfs/FanConf") }

        var fanLayouts: [FanLayout] = []
        var profileSets: [FanProfileSet] = []

        for fanNode in fanNodes {
            let rpm: RPMLayout?
            if let rpmNode = fanNode.child("RPMConf") {
                rpm = RPMLayout(
                    reg: rpmNode.byte("ReadReg"),
                    is16Bit: rpmNode.bool("Is16Bit", default: true),
                    isBigEndian: rpmNode.bool("IsBigEndian", default: true),
                    mult: rpmNode.int("RPMMult", default: 1),
                    divideByMult: rpmNode.bool("DivideByMult"),
                    invert: rpmNode.bool("Invert")
                )
            } else {
                rpm = nil
            }

            fanLayouts.append(FanLayout(
                name: fanNode.string("Name", default: "Fan"),
                minSpeed: fanNode.int("MinSpeed", default: 0),
                maxSpeed: fanNode.int("MaxSpeed", default: 100),
                speedReadReg: fanNode.byte("SpeedReadReg"),
                tempReadReg: fanNode.byte("TempReadReg"),
                upRegs: fanNode.bytes("UpThresholdRegs"),
                downRegs: fanNode.bytes("DownThresholdRegs"),
                curveRegs: fanNode.bytes("FanCurveRegs"),
                rpm: rpm
            ))

            let curveNodes = fanNode.child("FanCurveConfs")?.children("FanCurveConf") ?? []
            let profiles = curveNodes.map { curve -> FanProfile in
                let thresholds = (curve.child("TempThresholds")?.children("TempThreshold") ?? []).map {
                    TempThreshold(up: $0.int("UpThreshold"),
                                  down: $0.int("DownThreshold"),
                                  speed: $0.int("FanSpeed"))
                }
                return FanProfile(name: curve.string("Name", default: "Profile"),
                                  desc: curve.string("Desc"),
                                  perfMode: curve.int("PerfModeSel", default: -1),
                                  thresholds: thresholds)
            }
            profileSets.append(FanProfileSet(profiles: profiles,
                                             selected: fanNode.int("CurveSel", default: 0)))
        }

        let perf = enumLayout(from: root.child("PerfModeConf"), optionsTag: "PerfModes", optionTag: "PerfMode")
        let fanMode = enumLayout(from: root.child("FanModeConf"), optionsTag: "FanModes", optionTag: "FanMode")

        var settings = HardwareSettings()
        if let charge = root.child("ChargeLimitConf") {
            let minVal = charge.byte("MinVal", default: 0x80)
            let curVal = charge.int("CurVal", default: 0)
            settings.chargeLimit = max(0, min(100, curVal))
            settings.perfMode = perf?.defaultIndex ?? -1
            _ = minVal
        } else {
            settings.perfMode = perf?.defaultIndex ?? -1
        }
        if let fanMode {
            settings.fanMode = fanMode.defaultIndex
        }
        if let keySwap = root.child("KeySwapConf") {
            settings.keySwap = keySwap.bool("Enabled")
        }
        settings.fullBlast = false
        settings.keyLight = 0

        let layout = DeviceLayout(
            manufacturer: root.string("Manufacturer"),
            model: root.string("Model"),
            author: root.string("Author"),
            firmVer: root.string("FirmVer"),
            firmDate: emptyToNil(root.string("FirmDate")),
            firmVerSupported: root.bool("FirmVerSupported"),
            isNewEC: true,
            offsetDT: root.bool("OffsetDT", default: true),
            fans: fanLayouts,
            fullBlast: maskLayout(from: root.child("FullBlastConf")),
            chargeLimit: chargeLayout(from: root.child("ChargeLimitConf")),
            perfMode: perf,
            fanMode: fanMode,
            keyLight: rangeLayout(from: root.child("KeyLightConf")),
            keySwap: toggleLayout(from: root.child("KeySwapConf")),
            sourceVersion: 1
        )

        return YamdccConfig(version: 1, layout: layout, fans: profileSets, settings: settings)
    }

    // MARK: Version 2 (current YamdccCfg format)

    private static func parseV2(_ root: XMLNode) throws -> YamdccConfig {
        let isNewEC = root.bool("IsNewEC", default: true)
        let layout = BuiltinLayout.forNewEC(
            isNewEC,
            manufacturer: root.string("Manufacturer"),
            model: root.string("Model"),
            author: root.string("Author"),
            firmVer: root.string("FirmVer"),
            firmDate: emptyToNil(root.string("FirmDate")),
            offsetDT: root.bool("OffsetDT", default: true)
        )

        var sets: [FanProfileSet] = []
        for tag in ["CpuFan", "GpuFan"] {
            guard let fanNode = root.child(tag) else { throw ConfigError.missingElement(tag) }
            let profNodes = fanNode.child("FanProfs")?.children("FanProf") ?? []
            let profiles = profNodes.map { prof -> FanProfile in
                let thresholds = (prof.child("Thresholds")?.children("Threshold") ?? []).map {
                    TempThreshold(up: $0.int("Tup"),
                                  down: $0.int("Tdown"),
                                  speed: $0.int("Speed"))
                }
                return FanProfile(name: prof.string("Name", default: "Profile"),
                                  desc: prof.string("Desc"),
                                  perfMode: perfModeIndex(named: prof.string("PerfMode", default: "Default"),
                                                          in: layout),
                                  thresholds: thresholds)
            }
            sets.append(FanProfileSet(profiles: profiles,
                                      selected: fanNode.int("ProfSel", default: 0)))
        }

        if let first = sets.first, sets.contains(where: { $0.profiles.count != first.profiles.count }) {
            throw ConfigError.invalid("CPU 与 GPU 的曲线数量不一致")
        }

        var settings = HardwareSettings()
        settings.chargeLimit = max(0, min(100, root.int("ChargeLim", default: 0)))
        settings.perfMode = perfModeIndex(named: root.string("PerfMode", default: "Balanced"), in: layout)
        settings.fanMode = fanModeIndex(named: root.string("FanMode", default: "Advanced"), in: layout)
        settings.keySwap = root.bool("KeySwapEnabled")
        settings.fullBlast = false
        settings.keyLight = 0

        return YamdccConfig(version: 2, layout: layout, fans: sets, settings: settings)
    }

    // MARK: Small parsers

    private static func emptyToNil(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func maskLayout(from node: XMLNode?) -> MaskLayout? {
        guard let node else { return nil }
        return MaskLayout(reg: node.byte("Reg"), mask: node.byte("Mask"))
    }

    private static func rangeLayout(from node: XMLNode?) -> RangeLayout? {
        guard let node else { return nil }
        return RangeLayout(reg: node.byte("Reg"),
                           minVal: node.byte("MinVal"),
                           maxVal: node.byte("MaxVal"))
    }

    private static func toggleLayout(from node: XMLNode?) -> ToggleLayout? {
        guard let node else { return nil }
        return ToggleLayout(reg: node.byte("Reg"),
                            onVal: node.byte("OnVal"),
                            offVal: node.byte("OffVal"))
    }

    private static func chargeLayout(from node: XMLNode?) -> ChargeLayout? {
        guard let node else { return nil }
        return ChargeLayout(reg: node.byte("Reg"),
                            minVal: node.byte("MinVal", default: 0x80),
                            supportedMask: 0x80)
    }

    private static func enumLayout(from node: XMLNode?,
                                   optionsTag: String,
                                   optionTag: String) -> EnumLayout? {
        guard let node else { return nil }
        let options = (node.child(optionsTag)?.children(optionTag) ?? []).map {
            EnumOption(name: $0.string("Name"),
                       desc: $0.string("Desc"),
                       value: $0.byte("Value"))
        }
        return EnumLayout(reg: node.byte("Reg"),
                          options: options,
                          defaultIndex: node.int("ModeSel", default: 0))
    }

    private static func perfModeIndex(named name: String, in layout: DeviceLayout) -> Int {
        if name.lowercased() == "default" { return -1 }
        if let index = layout.perfMode?.options.firstIndex(where: {
            $0.name.lowercased() == name.lowercased()
        }) {
            return index
        }
        return -1
    }

    private static func fanModeIndex(named name: String, in layout: DeviceLayout) -> Int {
        if let index = layout.fanMode?.options.firstIndex(where: {
            $0.name.lowercased() == name.lowercased()
        }) {
            return index
        }
        return layout.fanMode?.defaultIndex ?? 3
    }

    // MARK: Writing

    public static func xmlString(for config: YamdccConfig) -> String {
        config.version == 2 ? xmlV2(config) : xmlV1(config)
    }

    public static func save(_ config: YamdccConfig, to url: URL) throws {
        let xml = xmlString(for: config)
        try xml.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func xmlV2(_ config: YamdccConfig) -> String {
        var builder = XMLBuilder()
        builder.raw("<?xml version=\"1.0\" encoding=\"utf-8\"?>")
        builder.open("YamdccCfg", attributes: [
            ("xmlns:xsd", "http://www.w3.org/2001/XMLSchema"),
            ("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance"),
            ("Ver", "2"),
        ])
        builder.element("Manufacturer", config.layout.manufacturer)
        builder.element("Model", config.layout.model)
        builder.element("Author", config.layout.author)
        builder.element("FirmVer", config.layout.firmVer)
        if let date = config.layout.firmDate {
            builder.element("FirmDate", date)
        }
        builder.element("IsNewEC", config.layout.isNewEC)
        builder.element("OffsetDT", config.layout.offsetDT)

        let tags = ["CpuFan", "GpuFan"]
        for (index, set) in config.fans.enumerated() where index < tags.count {
            builder.open(tags[index])
            builder.element("ProfSel", set.selected)
            builder.open("FanProfs")
            for profile in set.profiles {
                builder.open("FanProf")
                builder.element("Name", profile.name)
                builder.element("Desc", profile.desc)
                builder.element("PerfMode", perfModeName(profile.perfMode, in: config.layout))
                builder.open("Thresholds")
                for point in profile.thresholds {
                    builder.open("Threshold")
                    builder.element("Tup", point.up)
                    builder.element("Tdown", point.down)
                    builder.element("Speed", point.speed)
                    builder.close("Threshold")
                }
                builder.close("Thresholds")
                builder.close("FanProf")
            }
            builder.close("FanProfs")
            builder.close(tags[index])
        }

        builder.element("ChargeLim", config.settings.chargeLimit)
        builder.element("PerfMode", perfModeName(config.settings.perfMode, in: config.layout))
        builder.element("FanMode", fanModeName(config.settings.fanMode, in: config.layout))
        builder.element("KeySwapEnabled", config.settings.keySwap)
        builder.close("YamdccCfg")
        return builder.string
    }

    private static func perfModeName(_ index: Int, in layout: DeviceLayout) -> String {
        if index < 0 { return "Default" }
        guard let options = layout.perfMode?.options, options.indices.contains(index) else {
            return "Default"
        }
        return options[index].name
    }

    private static func fanModeName(_ index: Int, in layout: DeviceLayout) -> String {
        guard let options = layout.fanMode?.options, options.indices.contains(index) else {
            return layout.fanMode?.options.last?.name ?? "Advanced"
        }
        return options[index].name
    }

    private static func xmlV1(_ config: YamdccConfig) -> String {
        var builder = XMLBuilder()
        builder.raw("<?xml version=\"1.0\" encoding=\"utf-8\"?>")
        builder.open("YAMDCC_Config", attributes: [
            ("xmlns:xsd", "http://www.w3.org/2001/XMLSchema"),
            ("xmlns:xsi", "http://www.w3.org/2001/XMLSchema-instance"),
            ("Ver", "1"),
        ])
        builder.element("Manufacturer", config.layout.manufacturer)
        builder.element("Model", config.layout.model)
        builder.element("Author", config.layout.author)
        builder.element("FirmVerSupported", config.layout.firmVerSupported)
        if !config.layout.firmVer.isEmpty {
            builder.element("FirmVer", config.layout.firmVer)
        }
        if let date = config.layout.firmDate {
            builder.element("FirmDate", date)
        }
        builder.element("OffsetDT", config.layout.offsetDT)
        builder.open("FanConfs")
        for (index, fan) in config.layout.fans.enumerated() {
            let set = config.fans.indices.contains(index) ? config.fans[index] : FanProfileSet(profiles: [])
            builder.open("FanConf")
            builder.element("Name", fan.name)
            builder.element("MinSpeed", fan.minSpeed)
            builder.element("MaxSpeed", fan.maxSpeed)
            builder.element("CurveSel", set.selected)
            builder.element("SpeedReadReg", Int(fan.speedReadReg))
            builder.element("TempReadReg", Int(fan.tempReadReg))
            if let rpm = fan.rpm {
                builder.open("RPMConf")
                builder.element("ReadReg", Int(rpm.reg))
                builder.element("Is16Bit", rpm.is16Bit)
                builder.element("IsBigEndian", rpm.isBigEndian)
                builder.element("RPMMult", rpm.mult)
                builder.element("DivideByMult", rpm.divideByMult)
                builder.element("Invert", rpm.invert)
                builder.close("RPMConf")
            }
            builder.byteArray("UpThresholdRegs", fan.upRegs)
            builder.byteArray("DownThresholdRegs", fan.downRegs)
            builder.byteArray("FanCurveRegs", fan.curveRegs)
            builder.open("FanCurveConfs")
            for profile in set.profiles {
                builder.open("FanCurveConf")
                builder.element("Name", profile.name)
                builder.element("Desc", profile.desc)
                builder.element("PerfModeSel", profile.perfMode)
                builder.open("TempThresholds")
                for point in profile.thresholds {
                    builder.open("TempThreshold")
                    builder.element("UpThreshold", point.up)
                    builder.element("DownThreshold", point.down)
                    builder.element("FanSpeed", point.speed)
                    builder.close("TempThreshold")
                }
                builder.close("TempThresholds")
                builder.close("FanCurveConf")
            }
            builder.close("FanCurveConfs")
            builder.close("FanConf")
        }
        builder.close("FanConfs")

        if let fullBlast = config.layout.fullBlast {
            builder.open("FullBlastConf")
            builder.element("Reg", Int(fullBlast.reg))
            builder.element("Mask", Int(fullBlast.mask))
            builder.close("FullBlastConf")
        }
        if let charge = config.layout.chargeLimit {
            builder.open("ChargeLimitConf")
            builder.element("Reg", Int(charge.reg))
            builder.element("MinVal", Int(charge.minVal))
            builder.element("MaxVal", Int(min(255, Int(charge.minVal) + 100)))
            builder.element("CurVal", config.settings.chargeLimit)
            builder.close("ChargeLimitConf")
        }
        if let perf = config.layout.perfMode, !perf.options.isEmpty {
            builder.open("PerfModeConf")
            builder.element("Reg", Int(perf.reg))
            let perfSelection = config.settings.perfMode >= 0
                ? config.settings.perfMode : perf.defaultIndex
            builder.element("ModeSel", max(0, min(perfSelection, perf.options.count - 1)))
            builder.open("PerfModes")
            for option in perf.options {
                builder.open("PerfMode")
                builder.element("Name", option.name)
                builder.element("Desc", option.desc)
                builder.element("Value", Int(option.value))
                builder.close("PerfMode")
            }
            builder.close("PerfModes")
            builder.close("PerfModeConf")
        }
        if let fanMode = config.layout.fanMode, !fanMode.options.isEmpty {
            builder.open("FanModeConf")
            builder.element("Reg", Int(fanMode.reg))
            let fanSelection = config.settings.fanMode >= 0
                ? config.settings.fanMode : fanMode.defaultIndex
            builder.element("ModeSel", max(0, min(fanSelection, fanMode.options.count - 1)))
            builder.open("FanModes")
            for option in fanMode.options {
                builder.open("FanMode")
                builder.element("Name", option.name)
                builder.element("Desc", option.desc)
                builder.element("Value", Int(option.value))
                builder.close("FanMode")
            }
            builder.close("FanModes")
            builder.close("FanModeConf")
        }
        if let keySwap = config.layout.keySwap {
            builder.open("KeySwapConf")
            builder.element("Reg", Int(keySwap.reg))
            builder.element("Enabled", config.settings.keySwap)
            builder.element("OnVal", Int(keySwap.onVal))
            builder.element("OffVal", Int(keySwap.offVal))
            builder.close("KeySwapConf")
        }
        if let keyLight = config.layout.keyLight {
            builder.open("KeyLightConf")
            builder.element("Reg", Int(keyLight.reg))
            builder.element("MinVal", Int(keyLight.minVal))
            builder.element("MaxVal", Int(keyLight.maxVal))
            builder.close("KeyLightConf")
        }
        builder.close("YAMDCC_Config")
        return builder.string
    }
}

// MARK: - XMLNode byte helper

public extension XMLNode {
    func byte(_ name: String, default fallback: UInt8 = 0) -> UInt8 {
        guard let node = child(name) else { return fallback }
        return UInt8(node.trimmedText) ?? fallback
    }
}
