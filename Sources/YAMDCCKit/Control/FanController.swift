// FanController.swift
// Applies YAMDCC configs to the EC and reads back live state.

import Foundation

public final class FanController: @unchecked Sendable {
    public let transport: ECTransport
    public private(set) var config: YamdccConfig

    private let lock = NSLock()

    public init(transport: ECTransport, config: YamdccConfig) {
        self.transport = transport
        self.config = config
        if let simulator = transport as? SimulatedECTransport {
            simulator.configure(layout: config.layout)
        }
    }

    public func updateConfig(_ config: YamdccConfig) {
        lock.lock()
        self.config = config
        lock.unlock()
    }

    // MARK: Applying

    /// Writes the selected fan curves and all hardware settings to the EC.
    public func apply(_ config: YamdccConfig? = nil) throws {
        lock.lock()
        defer { lock.unlock() }
        if let config { self.config = config }
        let config = self.config
        let layout = config.layout

        Log.shared.info("开始应用配置「\(layout.displayName)」")

        // Put the EC into the requested fan mode first, so that the custom
        // curve registers are honoured by the firmware.
        if let fanMode = layout.fanMode,
           fanMode.options.indices.contains(config.settings.fanMode) {
            try safeWrite(fanMode.reg, fanMode.options[config.settings.fanMode].value,
                          name: "风扇模式")
        }

        for (fanIndex, fan) in layout.fans.enumerated() {
            guard config.fans.indices.contains(fanIndex),
                  let profile = config.fans[fanIndex].current else { continue }
            Log.shared.debug("应用风扇 \(fanIndex + 1)「\(profile.name)」")

            for (j, point) in profile.thresholds.enumerated() {
                guard fan.curveRegs.indices.contains(j) else { break }
                try safeWrite(fan.curveRegs[j], UInt8(clamping: point.speed), name: "转速曲线点 \(j + 1)")
                guard j > 0 else { continue }
                guard fan.upRegs.indices.contains(j - 1), fan.downRegs.indices.contains(j - 1) else { continue }
                try safeWrite(fan.upRegs[j - 1], UInt8(clamping: point.up), name: "上升阈值 \(j)")
                let downValue = layout.offsetDT ? max(0, point.up - point.down) : point.down
                try safeWrite(fan.downRegs[j - 1], UInt8(clamping: downValue), name: "下降阈值 \(j)")
            }

            // Performance mode is selected by the profile, falling back to the
            // config-wide selection, then the layout default.
            if fanIndex == 0, let perf = layout.perfMode {
                let index = resolvedPerfModeIndex(profile: profile, config: config, layout: layout)
                if perf.options.indices.contains(index) {
                    try safeWrite(perf.reg, perf.options[index].value, name: "性能模式")
                }
            }
        }

        try applyFullBlast(config.settings.fullBlast, layout: layout)
        if config.settings.chargeLimit > 0 {
            try applyChargeLimit(config.settings.chargeLimit, layout: layout)
        }
        if let keyLight = layout.keyLight {
            try safeWrite(keyLight.reg, keyLight.rawValue(percent: config.settings.keyLight),
                          name: "键盘背光")
        }
        if let keySwap = layout.keySwap {
            try safeWrite(keySwap.reg,
                          config.settings.keySwap ? keySwap.onVal : keySwap.offVal,
                          name: "Win/Fn 交换")
        }

        Log.shared.info("配置应用完成")
    }

    private func resolvedPerfModeIndex(profile: FanProfile, config: YamdccConfig, layout: DeviceLayout) -> Int {
        if profile.perfMode >= 0 { return profile.perfMode }
        if config.settings.perfMode >= 0 { return config.settings.perfMode }
        return layout.perfMode?.defaultIndex ?? 0
    }

    /// Writes a register, logging failures before re-throwing them.
    private func safeWrite(_ register: UInt8, _ value: UInt8, name: String) throws {
        do {
            try transport.write(register, value: value)
        } catch {
            Log.shared.error("写入\(name)（0x\(String(register, radix: 16))）失败：\(error.localizedDescription)")
            throw error
        }
    }

    // MARK: Individual settings

    public func applyFullBlast(_ enabled: Bool, layout: DeviceLayout? = nil) throws {
        let layout = layout ?? config.layout
        guard let fullBlast = layout.fullBlast else { return }
        // Read-modify-write: a failed read must abort, never be treated as 0.
        var value = try transport.read(fullBlast.reg)
        if enabled {
            value |= fullBlast.mask
        } else {
            value &= ~fullBlast.mask
        }
        try transport.write(fullBlast.reg, value: value)
        Log.shared.debug("Full Blast \(enabled ? "开" : "关")")
    }

    public func setFullBlast(_ enabled: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        try applyFullBlast(enabled)
        config.settings.fullBlast = enabled
    }

    public func applyChargeLimit(_ percent: Int, layout: DeviceLayout? = nil) throws {
        let layout = layout ?? config.layout
        guard let charge = layout.chargeLimit else {
            throw ECError.unsupported("电池充电限制")
        }
        let clamped = max(0, min(100, percent))
        try transport.write(charge.reg, value: charge.rawValue(percent: clamped))
        Log.shared.debug("充电限制写入 \(clamped)%")
    }

    public func setChargeLimit(_ percent: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        try applyChargeLimit(percent)
        config.settings.chargeLimit = max(0, min(100, percent))
    }

    public func setPerfMode(index: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let perf = config.layout.perfMode, perf.options.indices.contains(index) else {
            throw ECError.unsupported("性能模式")
        }
        try transport.write(perf.reg, value: perf.options[index].value)
        config.settings.perfMode = index
        Log.shared.debug("性能模式写入 \(perf.options[index].name)")
    }

    public func setFanMode(index: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let fanMode = config.layout.fanMode, fanMode.options.indices.contains(index) else {
            throw ECError.unsupported("风扇模式")
        }
        try transport.write(fanMode.reg, value: fanMode.options[index].value)
        config.settings.fanMode = index
        Log.shared.debug("风扇模式写入 \(fanMode.options[index].name)")
    }

    public func setKeyLight(_ percent: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let keyLight = config.layout.keyLight else {
            throw ECError.unsupported("键盘背光")
        }
        let clamped = max(0, min(100, percent))
        try transport.write(keyLight.reg, value: keyLight.rawValue(percent: clamped))
        config.settings.keyLight = clamped
    }

    public func setKeySwap(_ enabled: Bool) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let keySwap = config.layout.keySwap else {
            throw ECError.unsupported("Win/Fn 交换")
        }
        try transport.write(keySwap.reg, value: enabled ? keySwap.onVal : keySwap.offVal)
        config.settings.keySwap = enabled
    }

    // MARK: Reading

    public func readState() throws -> DeviceState {
        lock.lock()
        defer { lock.unlock() }
        let layout = config.layout
        var state = DeviceState()

        for fan in layout.fans {
            let temp = Int(try transport.read(fan.tempReadReg))
            let speed = Int(try transport.read(fan.speedReadReg))
            var rpm = 0
            if let rpmLayout = fan.rpm {
                if rpmLayout.is16Bit {
                    let raw = try transport.readWord(rpmLayout.reg, bigEndian: rpmLayout.isBigEndian)
                    rpm = rpmLayout.rpm(from: raw)
                } else {
                    let raw = try transport.read(rpmLayout.reg)
                    rpm = rpmLayout.rpm(from: UInt16(raw))
                }
            }
            state.temps.append(temp)
            state.speeds.append(speed)
            state.rpms.append(rpm)
        }

        if let fullBlast = layout.fullBlast {
            let value = try transport.read(fullBlast.reg)
            state.fullBlast = value & fullBlast.mask != 0
        }
        if let charge = layout.chargeLimit {
            let value = try transport.read(charge.reg)
            state.chargeLimit = charge.percent(rawValue: value)
        }
        if let perf = layout.perfMode {
            let value = try transport.read(perf.reg)
            state.perfModeValue = value
        }
        if let fanMode = layout.fanMode {
            let value = try transport.read(fanMode.reg)
            state.fanModeValue = value
        }
        if let keyLight = layout.keyLight {
            let value = try transport.read(keyLight.reg)
            state.keyLight = keyLight.percent(rawValue: value)
        }
        if let keySwap = layout.keySwap {
            let value = try transport.read(keySwap.reg)
            state.keySwap = value & keySwap.onVal == keySwap.onVal && keySwap.onVal != 0
        }
        state.timestamp = Date()
        return state
    }
}
