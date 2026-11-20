// SimulatedECTransport.swift
// A believable MSI EC simulator so the app can be explored without hardware.

import Foundation

public final class SimulatedECTransport: ECTransport {
    public let backendName = "模拟 EC（演示模式）"
    public let isSimulated = true

    public var details: [String: String] {
        [
            "驱动": "内置模拟器",
            "说明": "根据已应用的曲线模拟温度与转速",
            "端口": "无（纯软件）",
        ]
    }

    private let lock = NSLock()
    private var registers: [UInt8: UInt8] = [:]
    private var layout: DeviceLayout?
    private var tempValues: [Double] = [44, 41]
    private var fanValues: [Double] = [0, 0]
    private var load: Double = 0.3
    private var timer: DispatchSourceTimer?
    private var closed = false

    public init() {
        seedFirmware()
    }

    deinit {
        close()
    }

    // MARK: Setup

    public func configure(layout: DeviceLayout) {
        lock.lock()
        self.layout = layout
        registers.removeAll()
        tempValues = [44, 41]
        fanValues = [0, 0]
        seedFirmware()

        let defaultUps = [0, 46, 52, 58, 64, 70, 76]
        let defaultDowns = [0, 43, 49, 55, 61, 67, 73]
        let defaultSpeeds = [0, 32, 42, 54, 67, 82, 100]

        for (index, fan) in layout.fans.enumerated() {
            if tempValues.indices.contains(index) {
                registers[fan.tempReadReg] = UInt8(clamping: Int(tempValues[index].rounded()))
            }
            registers[fan.speedReadReg] = 0

            for (j, reg) in fan.curveRegs.enumerated() {
                let speed = j < defaultSpeeds.count ? defaultSpeeds[j] : 100
                registers[reg] = UInt8(clamping: speed)
                if j > 0 {
                    let up = j < defaultUps.count ? defaultUps[j] : min(100, 46 + j * 6)
                    let down = j < defaultDowns.count ? defaultDowns[j] : max(0, up - 3)
                    if fan.upRegs.indices.contains(j - 1) {
                        registers[fan.upRegs[j - 1]] = UInt8(clamping: up)
                    }
                    if fan.downRegs.indices.contains(j - 1) {
                        registers[fan.downRegs[j - 1]] = UInt8(clamping: layout.offsetDT ? max(0, up - down) : down)
                    }
                }
            }
        }

        if let charge = layout.chargeLimit {
            registers[charge.reg] = charge.rawValue(percent: 80)
        }
        if let perf = layout.perfMode {
            registers[perf.reg] = perf.options[perf.defaultIndex].value
        }
        if let fanMode = layout.fanMode {
            registers[fanMode.reg] = fanMode.options[fanMode.defaultIndex].value
        }
        if let keyLight = layout.keyLight {
            registers[keyLight.reg] = keyLight.minVal
        }
        if let keySwap = layout.keySwap {
            registers[keySwap.reg] = keySwap.offVal
        }
        if let fullBlast = layout.fullBlast {
            registers[fullBlast.reg] = 0
        }
        lock.unlock()

        startTimer()
    }

    private func seedFirmware() {
        let version = Array("158KEMS1.109".utf8)
        for (i, byte) in version.enumerated() where Int(0xA0) + i < 0xAC {
            registers[0xA0 + UInt8(i)] = byte
        }
        let date = Array("09/16/2021".utf8)
        for (i, byte) in date.enumerated() where Int(0xAC) + i < 0xBC {
            registers[0xAC + UInt8(i)] = byte
        }
    }

    private func startTimer() {
        lock.lock()
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.yamdcc.mac.simulator"))
        source.schedule(deadline: .now() + 0.5, repeating: 1.0, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        lock.unlock()
        source.resume()
    }

    // MARK: Simulation

    private func tick() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, let layout else { return }

        // Slow random walk of the simulated system load.
        load += Double.random(in: -0.09...0.09)
        load += (0.34 - load) * 0.04
        load = min(1.0, max(0.03, load))

        let bases: [Double] = [40, 37]
        for index in 0..<min(layout.fans.count, 2) {
            let target = bases[index] + load * 48
            tempValues[index] += (target - tempValues[index]) * 0.22
            tempValues[index] += Double.random(in: -0.25...0.25)
            let temp = max(20, min(105, Int(tempValues[index].rounded())))
            registers[layout.fans[index].tempReadReg] = UInt8(clamping: temp)
        }

        for index in 0..<layout.fans.count {
            let speed = evaluateCurve(fanIndex: index, layout: layout)
            fanValues[index] += (Double(speed) - fanValues[index]) * 0.35
            let rounded = max(0, min(100, Int(fanValues[index].rounded())))
            registers[layout.fans[index].speedReadReg] = UInt8(clamping: rounded)

            if let rpm = layout.fans[index].rpm {
                let rpmValue = rounded == 0 ? 0 : 900 + rounded * 38 + Int.random(in: -25...25)
                let raw = rpmValue == 0 ? 0 : UInt16(clamping: max(1, rpm.mult / max(1, rpmValue)))
                if rpm.is16Bit {
                    let high = UInt8(truncatingIfNeeded: raw >> 8)
                    let low = UInt8(truncatingIfNeeded: raw)
                    registers[rpm.reg] = rpm.isBigEndian ? high : low
                    registers[rpm.reg &+ 1] = rpm.isBigEndian ? low : high
                } else {
                    registers[rpm.reg] = UInt8(truncatingIfNeeded: raw)
                }
            }
        }
    }

    private func evaluateCurve(fanIndex: Int, layout: DeviceLayout) -> Int {
        let fan = layout.fans[fanIndex]
        let temp = Int(registers[fan.tempReadReg] ?? 0)

        if let fullBlast = layout.fullBlast,
           let value = registers[fullBlast.reg],
           value & fullBlast.mask != 0 {
            return 100
        }

        guard !fan.curveRegs.isEmpty else { return 0 }
        var index = 0
        for j in 1..<fan.curveRegs.count {
            let up = Int(registers[fan.upRegs[j - 1]] ?? 0)
            if temp >= up { index = j }
        }
        while index > 0 {
            let up = Int(registers[fan.upRegs[index - 1]] ?? 0)
            let downRaw = Int(registers[fan.downRegs[index - 1]] ?? 0)
            let down = layout.offsetDT ? up - downRaw : downRaw
            if temp < down {
                index -= 1
            } else {
                break
            }
        }
        return Int(registers[fan.curveRegs[index]] ?? 0)
    }

    // MARK: ECTransport

    public func read(_ register: UInt8) throws -> UInt8 {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw ECError.closed }
        return registers[register] ?? 0
    }

    public func write(_ register: UInt8, value: UInt8) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw ECError.closed }
        registers[register] = value
    }

    public func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        timer?.cancel()
        timer = nil
        lock.unlock()
    }
}
