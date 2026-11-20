// A one-shot diagnostic, intentionally separate from ECTransport. It never
// creates a simulator, uses a config, or starts monitoring.
import CryptoKit
import Darwin
import Foundation
import IOKit
import IOKit.pwr_mgt
import YAMDCCKit

struct ReadOnlyECProbe {
    private let bytes: [UInt8]
    private static let clientType: UInt32 = 0x59414d44 // "YAMD" in MSIECMatch.cpp
    private static let snapshotSelector: UInt32 = 0
    private static let abiVersion = 2 // MSIEC 1.0.3
    private static let fieldNames = ["TD68", "TD80", "TD71", "TD89", "TDC8", "TDC9", "TDCA", "TDCB"]
    private static let headerWords = 2
    private static var replyWords: Int { headerWords + fieldNames.count }

    // Compare the effective DSDT and the unordered set of SSDTs exported by
    // AppleACPIPlatformExpert to the firmware inspected on this machine.
    // The kext independently checks the EC provider, DSDT and readiness.
    private static func verifyAuditedTables() throws {
        func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let expert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleACPIPlatformExpert"))
        guard expert != 0 else { throw ECError.driverUnavailable("未找到 AppleACPIPlatformExpert") }
        defer { IOObjectRelease(expert) }
        guard let tables = IORegistryEntryCreateCFProperty(expert, "ACPI Tables" as CFString,
                                                           kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Data],
              let dsdt = tables["DSDT"], tables["ECDT"] == nil else {
            throw ECError.driverUnavailable("无法确认当前 ACPI 表；未执行探测")
        }
        // Exclude YAMDCC's own helper table so the audited firmware digest is
        // unchanged whether or not the write helper is installed.
        let ssdts = tables.values.filter {
            $0.starts(with: [0x53, 0x53, 0x44, 0x54]) && // "SSDT"
            !($0.count >= 24 && String(decoding: $0[16..<24], as: UTF8.self).hasPrefix("ECCTL"))
        }
        let hashes = ssdts.map { Data(SHA256.hash(data: $0)) }.sorted { $0.lexicographicallyPrecedes($1) }
        guard digest(dsdt) == "7858ecce69f96fed4c2efdfc27d78188bbd3f4d6d09ae22d4a03e603d4d510d6",
              ssdts.count == 23,
              digest(Data(hashes.joined())) == "54ab7ff8d1147a9089dbec02afcd34ffcb01529f2b117f1fad7e8678f9524ddd" else {
            throw ECError.driverUnavailable("当前 DSDT 或 SSDT 与已核对的固件不同；未执行探测")
        }
    }

    static func readOnce() throws -> Self {
        guard let matching = IOServiceMatching("com_yamdcc_MSIEC") else {
            throw ECError.driverUnavailable("无法创建 MSIEC 类匹配条件")
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else {
            throw ECError.driverUnavailable("未找到 com_yamdcc_MSIEC 服务")
        }
        defer { IOObjectRelease(service) }
        let access = IORegistryEntryCreateCFProperty(service, "MSIECAccess" as CFString,
                                                    kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        guard access == "acpi-probe" || access == "coordinated" else {
            throw ECError.driverUnavailable("MSIECAccess = \(access ?? "未声明")；需要已加载的 MSIEC 1.1.0 及匹配的 EC 路径")
        }
        let abi = IORegistryEntryCreateCFProperty(service, "MSIECProbeABI" as CFString,
                                                 kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber
        guard abi?.intValue == abiVersion else {
            throw ECError.driverUnavailable("MSIEC 只读诊断接口不匹配（需要 1.0.3 / ABI \(abiVersion)）；未执行探测")
        }
        guard geteuid() == 0 else {
            throw ECError.driverUnavailable("只读真机探测需要使用 sudo 执行")
        }

        try verifyAuditedTables()

        // Prevent idle sleep during the synchronous diagnostic (this does not
        // prevent lid-close or user-initiated sleep).
        var assertion: IOPMAssertionID = 0
        let power = IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "YAMDCC one-shot EC diagnostic" as CFString, &assertion)
        guard power == KERN_SUCCESS else { throw ECError.ioError("保持系统唤醒", power) }
        defer { IOPMAssertionRelease(assertion) }

        var connection: io_connect_t = 0
        let open = IOServiceOpen(service, mach_task_self_, clientType, &connection)
        guard open == KERN_SUCCESS else { throw ECError.ioError("打开 ACPI 只读诊断连接", open) }
        defer { IOServiceClose(connection) }

        var values = [UInt64](repeating: 0, count: replyWords)
        var count = UInt32(replyWords)
        let status = values.withUnsafeMutableBufferPointer { buffer in
            IOConnectCallScalarMethod(connection, snapshotSelector, nil, 0, buffer.baseAddress, &count)
        }
        guard status == KERN_SUCCESS else {
            throw ECError.ioError("IOKit 诊断调用（未收到采样回复；\(reason(status))）", status)
        }
        return try decodeReply(values, count: count)
    }

    private static func reason(_ status: kern_return_t) -> String {
        mach_error_string(status).map { String(cString: $0) } ?? "未知错误"
    }

    static func decodeReply(_ values: [UInt64], count: UInt32) throws -> Self {
        guard values.count == replyWords, count == replyWords,
              let code = UInt32(exactly: values[1]), (values[0] == 0) == (code == 0) else {
            throw ECError.driverUnavailable("驱动返回了不符合约定的诊断回复")
        }
        let stage = values[0]
        if code != 0 {
            let operation: String
            switch stage {
            case 1: operation = "EC 设备状态检查"
            case 2: operation = "探测频率限制"
            case 3: operation = "AppleACPIEC 就绪检查"
            case 4: operation = "内核 DSDT 指纹核对"
            case 5: operation = "定位 SCM0 ACPI 子设备"
            case 6: operation = "EC.MYEC 就绪检查"
            case 0x100..<(0x100 + UInt64(fieldNames.count)):
                operation = "读取 SCM0.\(fieldNames[Int(stage - 0x100)])"
            default: operation = "只读探测（阶段 \(stage)）"
            }
            let status = Int32(bitPattern: code)
            throw ECError.ioError("\(operation)（\(reason(status))）", status)
        }
        let bytes = values.dropFirst(headerWords)
        guard bytes.allSatisfy({ $0 <= UInt8.max }) else {
            throw ECError.driverUnavailable("驱动返回了非字节的 EC 读数")
        }
        return Self(bytes: bytes.map { UInt8($0) })
    }

    func sample(capturedAt: Date = Date()) -> ECTelemetrySample {
        // Field order: TD68/TD80, TD71/TD89, TDC8/TDC9, TDCA/TDCB.
        func reading(temperature: UInt8, duty: UInt8, tachHigh: UInt8, tachLow: UInt8) -> ECFanReading {
            let period = (UInt16(tachHigh) << 8) | UInt16(tachLow)
            let rpm = period == 0 || period == .max ? nil : 478_000 / Int(period)
            return ECFanReading(
                temperatureC: ECFanReading.temperatureRange.contains(Int(temperature)) ? Int(temperature) : nil,
                dutyPercent: ECFanReading.dutyRange.contains(Int(duty)) ? Int(duty) : nil,
                estimatedRPM: rpm.flatMap { ECFanReading.estimatedRPMRange.contains($0) ? $0 : nil }
            )
        }
        return ECTelemetrySample(
            capturedAt: capturedAt,
            cpu: reading(temperature: bytes[0], duty: bytes[2], tachHigh: bytes[4], tachLow: bytes[5]),
            gpu: reading(temperature: bytes[1], duty: bytes[3], tachHigh: bytes[6], tachLow: bytes[7])
        )
    }

    func report(_ sample: ECTelemetrySample) -> String {
        func fanLine(_ name: String, _ reading: ECFanReading) -> String {
            let temp = reading.temperatureC.map { "\($0) °C" } ?? "未报告"
            let duty = reading.dutyPercent.map { "\($0)%" } ?? "未报告"
            let rpm = reading.estimatedRPM.map { "\($0) RPM（估算）" } ?? "未报告"
            return "\(name)：温度 \(temp)，占空比 \(duty)，转速 \(rpm)"
        }
        let raw = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
        return [
            "后端：MSIEC / AppleACPIEC（真机，只读单次采样）",
            "原始值 [68 80 71 89 C8 C9 CA CB]：\(raw)",
            fanLine("CPU", sample.cpu),
            fanLine("GPU", sample.gpu),
        ].joined(separator: "\n")
    }
}
