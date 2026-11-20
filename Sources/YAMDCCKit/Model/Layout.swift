// Layout.swift
// Register layouts for MSI EC fan control.
//
// The register maps below are a port of YAMDCC's Ring0FanController
// (YAMDCC.Service/FanControllers/Ring0FanController.cs). YAMDCC is
// GPL-3.0-or-later, so is this file.

import Foundation

// MARK: - Register building blocks

public struct RPMLayout: Codable, Equatable, Sendable {
    public var reg: UInt8
    public var is16Bit: Bool
    public var isBigEndian: Bool
    public var mult: Int
    public var divideByMult: Bool
    public var invert: Bool

    public init(reg: UInt8, is16Bit: Bool = true, isBigEndian: Bool = true,
                mult: Int = 478000, divideByMult: Bool = true, invert: Bool = true) {
        self.reg = reg
        self.is16Bit = is16Bit
        self.isBigEndian = isBigEndian
        self.mult = mult
        self.divideByMult = divideByMult
        self.invert = invert
    }

    /// Converts a raw register value into RPM, mirroring the Windows service.
    public func rpm(from raw: UInt16) -> Int {
        guard raw > 0 else { return 0 }
        var value = Double(raw)
        if divideByMult {
            value /= Double(mult)
        } else {
            value *= Double(mult)
        }
        if invert, value != 0 {
            value = 1.0 / value
        }
        return Int(value.rounded())
    }
}

public struct MaskLayout: Codable, Equatable, Sendable {
    public var reg: UInt8
    public var mask: UInt8

    public init(reg: UInt8, mask: UInt8) {
        self.reg = reg
        self.mask = mask
    }
}

/// A register with a contiguous value range (keyboard backlight).
public struct RangeLayout: Codable, Equatable, Sendable {
    public var reg: UInt8
    public var minVal: UInt8
    public var maxVal: UInt8

    public init(reg: UInt8, minVal: UInt8, maxVal: UInt8) {
        self.reg = reg
        self.minVal = minVal
        self.maxVal = maxVal
    }

    public var levels: Int { max(1, Int(maxVal) - Int(minVal)) }

    /// Maps a 0...100 percentage onto the register range.
    public func rawValue(percent: Int) -> UInt8 {
        let clamped = max(0, min(100, percent))
        let level = Int((Double(clamped) / 100.0 * Double(levels)).rounded())
        return UInt8(clamping: Int(minVal) + level)
    }

    public func percent(rawValue: UInt8) -> Int? {
        guard rawValue >= minVal, rawValue <= maxVal else { return nil }
        let offset = Int(rawValue) - Int(minVal)
        return Int((Double(offset) / Double(levels) * 100.0).rounded())
    }
}

/// Charge limit register. Bit 0x80 marks "supported"; the lower 7 bits hold
/// the percentage.
public struct ChargeLayout: Codable, Equatable, Sendable {
    public var reg: UInt8
    /// Raw value that corresponds to a 0% charge limit (0x80 on MSI ECs).
    public var minVal: UInt8
    public var supportedMask: UInt8

    public init(reg: UInt8, minVal: UInt8 = 0x80, supportedMask: UInt8 = 0x80) {
        self.reg = reg
        self.minVal = minVal
        self.supportedMask = supportedMask
    }

    /// Raw register value for a percentage, including the "supported" bit.
    public func rawValue(percent: Int) -> UInt8 {
        let clamped = max(0, min(100, percent))
        return minVal &+ UInt8(clamping: clamped)
    }

    /// Decodes the percentage from a raw register value, if supported.
    public func percent(rawValue: UInt8) -> Int? {
        guard rawValue & supportedMask == supportedMask else { return nil }
        let value = Int(rawValue) - Int(minVal)
        guard value >= 0, value <= 100 else { return nil }
        return value
    }
}

public struct ToggleLayout: Codable, Equatable, Sendable {
    public var reg: UInt8
    public var onVal: UInt8
    public var offVal: UInt8

    public init(reg: UInt8, onVal: UInt8, offVal: UInt8 = 0) {
        self.reg = reg
        self.onVal = onVal
        self.offVal = offVal
    }
}

public extension EnumOption {
    /// Option name without the vendor's "(default)" annotation, for display.
    var displayName: String {
        name.replacingOccurrences(of: " (default)", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
    }
}

public struct EnumOption: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var desc: String
    public var value: UInt8

    public init(name: String, desc: String = "", value: UInt8) {
        self.name = name
        self.desc = desc
        self.value = value
    }
}

public struct EnumLayout: Codable, Equatable, Sendable {
    public var reg: UInt8
    public var options: [EnumOption]
    public var defaultIndex: Int

    public init(reg: UInt8, options: [EnumOption], defaultIndex: Int) {
        self.reg = reg
        self.options = options
        self.defaultIndex = defaultIndex
    }

    public func index(forValue value: UInt8) -> Int? {
        options.firstIndex { $0.value == value }
    }

    public func value(at index: Int) -> UInt8? {
        guard options.indices.contains(index) else { return nil }
        return options[index].value
    }
}

// MARK: - Fan layout

public struct FanLayout: Codable, Equatable, Sendable {
    public var name: String
    public var minSpeed: Int
    public var maxSpeed: Int
    public var speedReadReg: UInt8
    public var tempReadReg: UInt8
    public var upRegs: [UInt8]
    public var downRegs: [UInt8]
    public var curveRegs: [UInt8]
    public var rpm: RPMLayout?

    public init(name: String, minSpeed: Int = 0, maxSpeed: Int = 100,
                speedReadReg: UInt8, tempReadReg: UInt8,
                upRegs: [UInt8], downRegs: [UInt8], curveRegs: [UInt8],
                rpm: RPMLayout?) {
        self.name = name
        self.minSpeed = minSpeed
        self.maxSpeed = maxSpeed
        self.speedReadReg = speedReadReg
        self.tempReadReg = tempReadReg
        self.upRegs = upRegs
        self.downRegs = downRegs
        self.curveRegs = curveRegs
        self.rpm = rpm
    }

    /// Number of curve points supported by this fan (7 on MSI laptops).
    public var curvePointCount: Int { curveRegs.count }

    public var registerProblems: [String] {
        var issues: [String] = []
        if curveRegs.isEmpty { issues.append("风扇曲线寄存器为空") }
        if upRegs.count != max(0, curveRegs.count - 1) {
            issues.append("上升阈值寄存器数量应为 \(max(0, curveRegs.count - 1))")
        }
        if downRegs.count != max(0, curveRegs.count - 1) {
            issues.append("下降阈值寄存器数量应为 \(max(0, curveRegs.count - 1))")
        }
        if speedReadReg == 0 { issues.append("转速读取寄存器为 0") }
        if tempReadReg == 0 { issues.append("温度读取寄存器为 0") }
        return issues
    }
}

// MARK: - Whole device layout

public struct DeviceLayout: Codable, Equatable, Sendable {
    public var manufacturer: String
    public var model: String
    public var author: String
    public var firmVer: String
    public var firmDate: String?
    public var firmVerSupported: Bool
    public var isNewEC: Bool
    public var offsetDT: Bool
    public var fans: [FanLayout]
    public var fullBlast: MaskLayout?
    public var chargeLimit: ChargeLayout?
    public var perfMode: EnumLayout?
    public var fanMode: EnumLayout?
    public var keyLight: RangeLayout?
    public var keySwap: ToggleLayout?
    /// 1 for legacy YAMDCC configs, 2 for the current YamdccCfg format.
    public var sourceVersion: Int

    public init(manufacturer: String, model: String, author: String,
                firmVer: String = "", firmDate: String? = nil,
                firmVerSupported: Bool = false, isNewEC: Bool = true,
                offsetDT: Bool = true, fans: [FanLayout],
                fullBlast: MaskLayout?, chargeLimit: ChargeLayout?,
                perfMode: EnumLayout?, fanMode: EnumLayout?,
                keyLight: RangeLayout?, keySwap: ToggleLayout?,
                sourceVersion: Int) {
        self.manufacturer = manufacturer
        self.model = model
        self.author = author
        self.firmVer = firmVer
        self.firmDate = firmDate
        self.firmVerSupported = firmVerSupported
        self.isNewEC = isNewEC
        self.offsetDT = offsetDT
        self.fans = fans
        self.fullBlast = fullBlast
        self.chargeLimit = chargeLimit
        self.perfMode = perfMode
        self.fanMode = fanMode
        self.keyLight = keyLight
        self.keySwap = keySwap
        self.sourceVersion = sourceVersion
    }

    public var fanCount: Int { fans.count }
    public var displayName: String {
        [manufacturer, model].filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var registerProblems: [String] {
        var issues: [String] = []
        if fans.isEmpty { issues.append("没有风扇配置") }
        for (i, fan) in fans.enumerated() {
            issues.append(contentsOf: fan.registerProblems.map { "风扇 \(i + 1): \($0)" })
        }
        return issues
    }
}

// MARK: - Built-in layouts for YamdccCfg (version 2) configs

public enum BuiltinLayout {

    public static func cpuFan() -> FanLayout {
        FanLayout(
            name: "CPU Fan",
            speedReadReg: 0x71,
            tempReadReg: 0x68,
            upRegs: [0x6A, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F],
            downRegs: [0x7A, 0x7B, 0x7C, 0x7D, 0x7E, 0x7F],
            curveRegs: [0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78],
            rpm: RPMLayout(reg: 0xC8)
        )
    }

    public static func gpuFan() -> FanLayout {
        FanLayout(
            name: "GPU Fan",
            speedReadReg: 0x89,
            tempReadReg: 0x80,
            upRegs: [0x82, 0x83, 0x84, 0x85, 0x86, 0x87],
            downRegs: [0x92, 0x93, 0x94, 0x95, 0x96, 0x97],
            curveRegs: [0x8A, 0x8B, 0x8C, 0x8D, 0x8E, 0x8F, 0x90],
            rpm: RPMLayout(reg: 0xCA)
        )
    }

    public static let perfModes = EnumLayout(
        reg: 0xD2,
        options: [
            EnumOption(name: "MaxBattery", desc: "最大续航", value: 0xC2),
            EnumOption(name: "Silent", desc: "静音", value: 0xC1),
            EnumOption(name: "Balanced", desc: "均衡", value: 0xC0),
            EnumOption(name: "Performance", desc: "高性能", value: 0xC4),
        ],
        defaultIndex: 2
    )

    public static let fanModes = EnumLayout(
        reg: 0xD4,
        options: [
            EnumOption(name: "Auto", desc: "自动", value: 0x0D),
            EnumOption(name: "Silent", desc: "静音", value: 0x1D),
            EnumOption(name: "Basic", desc: "基础", value: 0x4D),
            EnumOption(name: "Advanced", desc: "高级（自定义曲线）", value: 0x8D),
        ],
        defaultIndex: 3
    )

    /// Layout for a YamdccCfg v2 config.
    public static func forNewEC(_ isNewEC: Bool,
                                manufacturer: String,
                                model: String,
                                author: String,
                                firmVer: String = "",
                                firmDate: String? = nil,
                                offsetDT: Bool = true) -> DeviceLayout {
        var perf = perfModes
        var fanMode = fanModes
        var keyLight: RangeLayout?
        var keySwap: ToggleLayout?
        var charge: ChargeLayout

        if isNewEC {
            perf.reg = 0xD2
            fanMode.reg = 0xD4
            charge = ChargeLayout(reg: 0xD7)
            keyLight = RangeLayout(reg: 0xD3, minVal: 0x80, maxVal: 0x83)
            keySwap = ToggleLayout(reg: 0xE8, onVal: 0x10, offVal: 0x00)
        } else {
            perf.reg = 0xF2
            fanMode.reg = 0xF4
            charge = ChargeLayout(reg: 0xEF)
            keyLight = RangeLayout(reg: 0xF3, minVal: 0x80, maxVal: 0x83)
            keySwap = nil
        }

        return DeviceLayout(
            manufacturer: manufacturer,
            model: model,
            author: author,
            firmVer: firmVer,
            firmDate: firmDate,
            firmVerSupported: true,
            isNewEC: isNewEC,
            offsetDT: offsetDT,
            fans: [cpuFan(), gpuFan()],
            fullBlast: MaskLayout(reg: 0x98, mask: 0x80),
            chargeLimit: charge,
            perfMode: perf,
            fanMode: fanMode,
            keyLight: keyLight,
            keySwap: keySwap,
            sourceVersion: 2
        )
    }
}
