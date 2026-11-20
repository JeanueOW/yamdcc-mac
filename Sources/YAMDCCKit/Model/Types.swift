// Types.swift
// Core value types shared by the config model, the EC controller and the UI.

import Foundation

// MARK: - Fan identity

public enum FanTarget: Int, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case cpu = 0
    case gpu = 1

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .cpu: return "CPU 风扇"
        case .gpu: return "GPU 风扇"
        }
    }

    public var shortName: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        }
    }

    public var symbolName: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "display"
        }
    }
}

// MARK: - Fan curve

/// One point of a MSI EC fan curve.
///
/// The EC keeps a table of up to `n` speed points with `n-1` hysteresis
/// thresholds in between. `up` is the temperature at which the fan ramps to
/// `speed`, `down` is the temperature at which it drops back to the previous
/// point again.
public struct TempThreshold: Codable, Equatable, Hashable, Sendable {
    public var up: Int
    public var down: Int
    public var speed: Int

    public init(up: Int, down: Int, speed: Int) {
        self.up = up
        self.down = down
        self.speed = speed
    }
}

public struct FanProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var desc: String
    /// Index into the performance mode list, or -1 for "use the default".
    public var perfMode: Int
    public var thresholds: [TempThreshold]

    public init(id: UUID = UUID(),
                name: String,
                desc: String = "",
                perfMode: Int = -1,
                thresholds: [TempThreshold]) {
        self.id = id
        self.name = name
        self.desc = desc
        self.perfMode = perfMode
        self.thresholds = thresholds
    }

    public init(name: String, desc: String = "", perfMode: Int = -1,
                ups: [Int], downs: [Int], speeds: [Int]) {
        let count = min(ups.count, min(downs.count, speeds.count))
        var points: [TempThreshold] = []
        for i in 0..<count {
            points.append(TempThreshold(up: ups[i], down: downs[i], speed: speeds[i]))
        }
        self.init(name: name, desc: desc, perfMode: perfMode, thresholds: points)
    }

    /// A copy with fresh identity, useful for duplication.
    public func duplicated(name: String? = nil) -> FanProfile {
        FanProfile(name: name ?? (self.name + " 副本"),
                   desc: desc,
                   perfMode: perfMode,
                   thresholds: thresholds)
    }

    public var pointCount: Int { thresholds.count }

    /// A curve that mirrors YAMDCC's defaults for laptops that do not ship one.
    public static func defaultProfile(for fan: FanLayout) -> FanProfile {
        let count = max(2, fan.curvePointCount)
        let presetUps = [46, 52, 58, 64, 70, 76, 82]
        let presetSpeeds = [0, 32, 42, 54, 67, 82, 100]
        var thresholds: [TempThreshold] = []
        thresholds.reserveCapacity(count)
        for index in 0..<count {
            let ratio = Double(index) / Double(count - 1)
            let up: Int
            let speed: Int
            if count == 7 {
                up = presetUps[index]
                speed = presetSpeeds[index]
            } else {
                up = Int((42.0 + ratio * 38.0).rounded())
                speed = Int((ratio * 100.0).rounded())
            }
            thresholds.append(TempThreshold(up: up, down: max(30, up - 3), speed: speed))
        }
        return FanProfile(name: "默认", desc: "自动生成的风扇曲线",
                          perfMode: -1, thresholds: thresholds)
    }

    public static func == (lhs: FanProfile, rhs: FanProfile) -> Bool {
        lhs.name == rhs.name &&
            lhs.desc == rhs.desc &&
            lhs.perfMode == rhs.perfMode &&
            lhs.thresholds == rhs.thresholds
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(desc)
        hasher.combine(perfMode)
        hasher.combine(thresholds)
    }

    /// Validates ordering and ranges. Returns human readable problems.
    public func problems(minSpeed: Int = 0, maxSpeed: Int = 100) -> [String] {
        var issues: [String] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            issues.append("曲线名称不能为空")
        }
        if thresholds.isEmpty {
            issues.append("曲线至少需要一个点")
            return issues
        }
        for (i, t) in thresholds.enumerated() {
            if t.speed < minSpeed || t.speed > maxSpeed {
                issues.append("第 \(i + 1) 点转速 \(t.speed)% 超出 \(minSpeed)–\(maxSpeed)%")
            }
            if i == 0 {
                if t.up != 0 {
                    issues.append("第一个温度点必须为 0°C")
                }
                continue
            }
            if t.up <= thresholds[i - 1].up {
                issues.append("上升温度必须严格递增（第 \(i + 1) 点）")
            }
            if t.down > t.up {
                issues.append("下降温度不能高于上升温度（第 \(i + 1) 点）")
            }
            if t.down < 0 || t.up > 110 {
                issues.append("第 \(i + 1) 点温度超出 0–110°C")
            }
        }
        return issues
    }

    /// Fan speed (percent) the EC would pick for `temperature`, using the same
    /// hysteresis rules as the firmware: ramp up at `up`, drop only below `down`.
    public func speed(for temperature: Int, previousIndex: Int) -> (speed: Int, index: Int) {
        guard !thresholds.isEmpty else { return (0, 0) }
        var index = max(0, min(previousIndex, thresholds.count - 1))
        // Ramp up as far as possible.
        while index + 1 < thresholds.count, temperature >= thresholds[index + 1].up {
            index += 1
        }
        // Drop down while the temperature is below the lower hysteresis bound.
        while index > 0, temperature < thresholds[index].down {
            index -= 1
        }
        return (thresholds[index].speed, index)
    }
}

// MARK: - Hardware settings

public struct HardwareSettings: Codable, Equatable, Sendable {
    /// 0 = charge limit disabled, 1...100 = target charge percentage.
    public var chargeLimit: Int
    /// Index into the performance-mode option list, or -1 for "default".
    public var perfMode: Int
    /// Index into the fan-mode option list.
    public var fanMode: Int
    public var keySwap: Bool
    public var fullBlast: Bool
    /// Keyboard backlight brightness in percent (0...100).
    public var keyLight: Int

    public init(chargeLimit: Int = 0,
                perfMode: Int = -1,
                fanMode: Int = 3,
                keySwap: Bool = false,
                fullBlast: Bool = false,
                keyLight: Int = 0) {
        self.chargeLimit = chargeLimit
        self.perfMode = perfMode
        self.fanMode = fanMode
        self.keySwap = keySwap
        self.fullBlast = fullBlast
        self.keyLight = keyLight
    }
}

// MARK: - Live device state

public struct DeviceState: Codable, Equatable, Sendable {
    public var temps: [Int]
    public var speeds: [Int]
    public var rpms: [Int]
    public var fullBlast: Bool
    /// nil when the EC does not report a supported charge limit.
    public var chargeLimit: Int?
    /// Raw performance mode register value.
    public var perfModeValue: UInt8?
    /// Raw fan mode register value.
    public var fanModeValue: UInt8?
    public var keyLight: Int?
    public var keySwap: Bool?
    public var timestamp: Date

    public init(temps: [Int] = [], speeds: [Int] = [], rpms: [Int] = [],
                fullBlast: Bool = false, chargeLimit: Int? = nil,
                perfModeValue: UInt8? = nil, fanModeValue: UInt8? = nil,
                keyLight: Int? = nil, keySwap: Bool? = nil,
                timestamp: Date = Date()) {
        self.temps = temps
        self.speeds = speeds
        self.rpms = rpms
        self.fullBlast = fullBlast
        self.chargeLimit = chargeLimit
        self.perfModeValue = perfModeValue
        self.fanModeValue = fanModeValue
        self.keyLight = keyLight
        self.keySwap = keySwap
        self.timestamp = timestamp
    }

    public func temp(_ target: FanTarget) -> Int? {
        temps.indices.contains(target.rawValue) ? temps[target.rawValue] : nil
    }

    public func speed(_ target: FanTarget) -> Int? {
        speeds.indices.contains(target.rawValue) ? speeds[target.rawValue] : nil
    }

    public func rpm(_ target: FanTarget) -> Int? {
        rpms.indices.contains(target.rawValue) ? rpms[target.rawValue] : nil
    }
}

// MARK: - Config catalog entry

public struct ConfigSummary: Identifiable, Hashable, Sendable {
    public var id: String { path.path }
    public var path: URL
    public var manufacturer: String
    public var model: String
    public var author: String
    public var version: Int
    public var fanCount: Int
    public var isBuiltin: Bool
    public var parseError: String?

    public var title: String {
        [manufacturer, model].filter { !$0.isEmpty }.joined(separator: " ")
    }
}
