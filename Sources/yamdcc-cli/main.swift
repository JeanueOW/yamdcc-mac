// yamdcc-cli — command line front end for YAMDCC for macOS.
//
// Examples:
//   yamdcc list
//   yamdcc status
//   yamdcc ec dump 0x60 32
//   yamdcc ec read 0x68
//   yamdcc apply --config ~/Library/Application\ Support/YAMDCC/Configs/MS-16V1.xml
//   yamdcc apply --simulate

import Foundation
import YAMDCCKit

// MARK: - Argument handling

struct CommandLineOptions {
    var simulate = false
    var requireReal = false
    var configPath: String?
    var positional: [String] = []
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func usage() -> Never {
    print("""
    yamdcc — MSI 风扇 / EC 控制

    用法:
      yamdcc list                      列出可用配置文件
      yamdcc status                    读取当前风扇 / 温度 / 转速
      yamdcc apply [--config PATH]     应用配置文件（未选择时使用 Vector 16 HX A14VHG）
      yamdcc watch [秒]                持续输出状态（默认 1 秒）

      sudo yamdcc ec probe [--json]    单次真机只读诊断（--json 可供 App 导入）
      yamdcc ec read <寄存器>          读取一个 EC 寄存器（支持 0x 前缀）
      yamdcc ec write <寄存器> <值>    写入一个 EC 寄存器
      yamdcc ec dump [起始] [数量]     转储 EC 内存（默认 0x00 / 256）

      yamdcc set fullblast on|off
      yamdcc set charge <0-100>
      yamdcc set perf <名称|序号>
      yamdcc set fan <名称|序号>
      yamdcc set keylight <0-100>
      yamdcc set keyswap on|off

    全局选项:
      --simulate, -s    使用模拟 EC（不需要驱动）
      --require-real    必须读到真实 EC；不回退到模拟模式
      --config PATH     指定配置文件
      --help, -h        显示帮助
    """)
    exit(0)
}

func parseArguments() -> CommandLineOptions {
    var options = CommandLineOptions()
    var iterator = CommandLine.arguments.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--simulate", "-s":
            options.simulate = true
        case "--require-real":
            options.requireReal = true
        case "--config", "-c":
            guard let value = iterator.next() else { fail("--config 需要一个路径") }
            options.configPath = value
        case "--help", "-h":
            usage()
        default:
            options.positional.append(arg)
        }
    }
    if options.simulate && options.requireReal {
        fail("--simulate 与 --require-real 不能同时使用", code: 2)
    }
    return options
}

// MARK: - Helpers

func parseByte(_ text: String) -> UInt8? {
    let trimmed = text.lowercased()
    if trimmed.hasPrefix("0x") {
        return UInt8(trimmed.dropFirst(2), radix: 16)
    }
    if let decimal = UInt8(trimmed) { return decimal }
    return UInt8(trimmed, radix: 16)
}

func parseUShort(_ text: String) -> Int? {
    let trimmed = text.lowercased()
    if trimmed.hasPrefix("0x") {
        return Int(trimmed.dropFirst(2), radix: 16)
    }
    return Int(trimmed) ?? Int(trimmed, radix: 16)
}

func parseOnOff(_ text: String) -> Bool? {
    switch text.lowercased() {
    case "on", "1", "true", "yes", "enable", "enabled": return true
    case "off", "0", "false", "no", "disable", "disabled": return false
    default: return nil
    }
}

func hex(_ value: UInt8) -> String {
    String(format: "0x%02X", value)
}

func resolveConfig(_ options: CommandLineOptions) -> YamdccConfig {
    let store = ConfigStore.shared
    if let path = options.configPath {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            return try store.load(url: url)
        } catch {
            fail("无法载入配置 \(url.path): \(error.localizedDescription)")
        }
    }

    store.seedLibraryIfNeeded()
    store.refresh()
    if let config = store.loadPreferred(activePath: SettingsStore.shared.settings.activeConfigPath) {
        return config
    }

    fail("找不到任何配置文件。请先运行 `yamdcc list`，或用 --config 指定。")
}

func connectEC(_ options: CommandLineOptions) -> (transport: ECTransport, info: ECInfo) {
    if options.requireReal {
        do {
            return try ECBackend.connectReal()
        } catch {
            fail("\(error.localizedDescription)；未使用模拟 EC。")
        }
    }
    guard options.simulate else {
        do {
            return try ECBackend.connectReal()
        } catch {
            fail("\(error.localizedDescription)；未使用模拟 EC。")
        }
    }
    return ECBackend.simulated()
}

func makeController(_ options: CommandLineOptions) -> (FanController, ECInfo) {
    let (transport, info) = connectEC(options)
    let config = resolveConfig(options)
    return (FanController(transport: transport, config: config), info)
}

func formatState(_ state: DeviceState, config: YamdccConfig) -> String {
    var lines: [String] = []
    lines.append("风扇:")
    for (index, fan) in config.layout.fans.enumerated() {
        let speed = index < state.speeds.count ? state.speeds[index] : 0
        let rpm = index < state.rpms.count ? state.rpms[index] : 0
        let temp = index < state.temps.count ? state.temps[index] : 0
        lines.append(String(format: "  %@: %3d%%   %4d RPM   %2d°C", fan.name, speed, rpm, temp))
    }
    lines.append("全速: \(state.fullBlast ? "开" : "关")")
    if let charge = state.chargeLimit {
        lines.append("充电上限: \(charge)%")
    }
    if let perf = state.perfModeValue,
       let option = config.layout.perfMode?.options.first(where: { $0.value == perf }) {
        lines.append("性能模式: \(option.name)")
    }
    if let fanMode = state.fanModeValue,
       let option = config.layout.fanMode?.options.first(where: { $0.value == fanMode }) {
        lines.append("风扇模式: \(option.name)")
    }
    if let keyLight = state.keyLight {
        lines.append("键盘背光: \(keyLight)%")
    }
    return lines.joined(separator: "\n")
}

// MARK: - Commands

let options = parseArguments()
guard let command = options.positional.first else { usage() }

switch command {
case "list":
    let store = ConfigStore.shared
    store.seedLibraryIfNeeded()
    store.refresh()
    if store.summaries.isEmpty {
        print("没有配置文件。")
    }
    for summary in store.summaries {
        let marker = summary.isBuiltin ? "[内置]" : "[用户]"
        print("\(marker) \(summary.title)  —  \(summary.path.lastPathComponent)")
        if let problem = summary.parseError {
            print("        ⚠︎ \(problem)")
        }
    }

case "status":
    let (controller, info) = makeController(options)
    print("后端: \(info.backend)\(info.isSimulated ? "（模拟）" : "")  固件: \(info.firmwareVersion) \(info.firmwareDate)")
    print("配置: \(controller.config.displayName)")
    do {
        print(try formatState(controller.readState(), config: controller.config))
    } catch {
        fail("读取 EC 失败: \(error.localizedDescription)")
    }

case "apply":
    let (controller, info) = makeController(options)
    print("后端: \(info.backend)\(info.isSimulated ? "（模拟）" : "")")
    do {
        try controller.apply()
        print("已应用配置: \(controller.config.displayName)")
        print(try formatState(controller.readState(), config: controller.config))
    } catch {
        fail("应用失败: \(error.localizedDescription)")
    }

case "watch":
    let (controller, info) = makeController(options)
    let interval = options.positional.count > 1 ? (Double(options.positional[1]) ?? 1) : 1
    print("后端: \(info.backend)\(info.isSimulated ? "（模拟）" : "")  按 Ctrl-C 退出")
    while true {
        do {
            print(try formatState(controller.readState(), config: controller.config))
        } catch {
            print("读取失败: \(error.localizedDescription)")
        }
        print("---")
        fflush(stdout)
        Thread.sleep(forTimeInterval: max(0.2, interval))
    }

case "ec":
    guard options.positional.count >= 2 else { fail("用法: yamdcc ec probe|read|write|dump ...") }
    let sub = options.positional[1]
    if sub == "probe" {
        let arguments = Array(options.positional.dropFirst(2))
        guard (arguments.isEmpty || arguments == ["--json"]), !options.simulate, options.configPath == nil else {
            fail("用法: sudo yamdcc [--require-real] ec probe [--json]（不接受模拟选项、机型配置或寄存器参数）", code: 2)
        }
        do {
            let probe = try ReadOnlyECProbe.readOnce()
            let sample = probe.sample()
            if !arguments.isEmpty {
                let data = try ECTelemetryCapture.encode(sample)
                try FileHandle.standardOutput.write(contentsOf: data + Data([0x0a]))
            } else {
                print(probe.report(sample))
                if sample.cpu.temperatureC == nil {
                    fail("CPU 温度字段未返回有效读数；未使用模拟 EC。")
                }
            }
        } catch {
            fail("\(error.localizedDescription)；未使用模拟 EC。")
        }
        break
    }
    let (transport, info) = connectEC(options)
    print("后端: \(info.backend)\(info.isSimulated ? "（模拟）" : "")")
    do {
        switch sub {
        case "read":
            guard options.positional.count >= 3, let reg = parseByte(options.positional[2]) else {
                fail("用法: yamdcc ec read <寄存器>")
            }
            print("\(hex(reg)) = \(hex(try transport.read(reg)))")
        case "write":
            guard options.positional.count >= 4,
                  let reg = parseByte(options.positional[2]),
                  let value = parseByte(options.positional[3]) else {
                fail("用法: yamdcc ec write <寄存器> <值>")
            }
            try transport.write(reg, value: value)
            print("已写入 \(hex(reg)) = \(hex(value))，回读 \(hex(try transport.read(reg)))")
        case "dump":
            let start = options.positional.count > 2 ? (parseUShort(options.positional[2]) ?? 0) : 0
            let count = options.positional.count > 3 ? (parseUShort(options.positional[3]) ?? 256) : 256
            var offset = 0
            while offset < count {
                let lineStart = start + offset
                var values: [String] = []
                for column in 0..<16 where offset + column < count {
                    let reg = UInt8((lineStart + column) & 0xFF)
                    values.append(hex(try transport.read(reg)))
                }
                print(String(format: "%04X  %@", lineStart, values.joined(separator: " ")))
                offset += 16
            }
        default:
            fail("未知的 ec 子命令: \(sub)")
        }
    } catch {
        fail("EC 操作失败: \(error.localizedDescription)")
    }

case "set":
    guard options.positional.count >= 2 else { fail("用法: yamdcc set <项> <值>") }
    let (controller, _) = makeController(options)
    let item = options.positional[1]
    let value = options.positional.count > 2 ? options.positional[2] : ""
    do {
        switch item {
        case "fullblast":
            guard let on = parseOnOff(value) else { fail("需要 on/off") }
            try controller.setFullBlast(on)
        case "charge":
            guard let percent = Int(value) else { fail("需要 0-100 的数字") }
            try controller.setChargeLimit(percent)
        case "keylight":
            guard let percent = Int(value) else { fail("需要 0-100 的数字") }
            try controller.setKeyLight(percent)
        case "keyswap":
            guard let on = parseOnOff(value) else { fail("需要 on/off") }
            try controller.setKeySwap(on)
        case "perf":
            let layout = controller.config.layout
            guard let layoutPerf = layout.perfMode else { fail("此配置不支持性能模式") }
            if let index = Int(value), layoutPerf.options.indices.contains(index) {
                try controller.setPerfMode(index: index)
            } else if let index = layoutPerf.options.firstIndex(where: { $0.name.lowercased() == value.lowercased() }) {
                try controller.setPerfMode(index: index)
            } else {
                fail("可用模式: \(layoutPerf.options.map(\.name).joined(separator: ", "))")
            }
        case "fan":
            let layout = controller.config.layout
            guard let layoutFan = layout.fanMode else { fail("此配置不支持风扇模式") }
            if let index = Int(value), layoutFan.options.indices.contains(index) {
                try controller.setFanMode(index: index)
            } else if let index = layoutFan.options.firstIndex(where: { $0.name.lowercased() == value.lowercased() }) {
                try controller.setFanMode(index: index)
            } else {
                fail("可用模式: \(layoutFan.options.map(\.name).joined(separator: ", "))")
            }
        default:
            fail("未知的设置项: \(item)")
        }
        print("已设置 \(item) = \(value)")
    } catch {
        fail("设置失败: \(error.localizedDescription)")
    }

default:
    fail("未知命令: \(command)\n运行 `yamdcc --help` 查看用法。")
}
