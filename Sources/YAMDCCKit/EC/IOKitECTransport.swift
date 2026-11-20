// IOKitECTransport.swift
// Userspace client for the MSIEC kernel extension.
//
// All accesses are mediated by the ACPI interpreter inside MSIEC, so
// AppleACPIEC performs the EC transaction. Selectors:
//   0: one-shot telemetry probe (ABI 2)
//   1: read(reg) -> value
//   2: write(reg, value) -> 1
//   3: readBlock(reg, length) -> bytes (struct output only)

import Foundation
import IOKit

public final class IOKitECTransport: ECTransport {
    public let backendName = "MSIEC kext"
    public let isSimulated = false

    private var connection: io_connect_t = 0
    private let queue = DispatchQueue(label: "com.yamdcc.mac.ec")
    private var isClosed = false

    public var details: [String: String] {
        [
            "驱动": "MSIEC",
            "SEL": "IOServiceOpen",
        ]
    }

    public init() throws {
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
        guard access == "coordinated" else {
            let reason: String
            switch access {
            case "match-only":
                reason = "MSIEC 已匹配，但当前仅验证设备匹配，未启用真实 EC I/O"
            case "acpi-probe":
                reason = "MSIEC 仅支持 `sudo yamdcc ec probe` 单次只读诊断，不支持常规监控或写入"
            default:
                reason = "MSIEC 未声明与系统 EC 驱动协调的访问模式"
            }
            throw ECError.driverUnavailable(reason)
        }

        var conn: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
        guard result == KERN_SUCCESS else { throw ECError.ioError("打开 MSIEC", result) }
        connection = conn
    }

    deinit {
        close()
    }

    public func close() {
        queue.sync {
            guard !isClosed, connection != 0 else { return }
            IOServiceClose(connection)
            connection = 0
            isClosed = true
        }
    }

    public func read(_ register: UInt8) throws -> UInt8 {
        let value = try call(selector: 1, input: [UInt64(register)])
        return UInt8(truncatingIfNeeded: value)
    }

    public func write(_ register: UInt8, value: UInt8) throws {
        do {
            _ = try call(selector: 2, input: [UInt64(register), UInt64(value)])
        } catch ECError.ioError(_, let code)
                    where code == Int32(bitPattern: 0xE000_02C2) {
            // The ACPI method returns no value, so evaluateInteger() reports
            // kIOReturnBadArgument *after* the store already happened. A real
            // store failure surfaces as a different ACPI/IOKit error.
            return
        }
    }

    public func readBlock(_ register: UInt8, length: Int) throws -> [UInt8] {
        guard length > 0, length <= 32 else {
            throw ECError.unsupported("块读取长度必须在 1…32 之间")
        }
        var output = [UInt8](repeating: 0, count: length)
        var outputCount = length
        var input = [UInt64(register), UInt64(length)]
        let result: kern_return_t = queue.sync {
            output.withUnsafeMutableBytes { buffer in
                input.withUnsafeMutableBufferPointer { inputBuffer in
                    IOConnectCallStructMethod(connection, 3,
                                              inputBuffer.baseAddress, 16,
                                              buffer.baseAddress, &outputCount)
                }
            }
        }
        guard result == KERN_SUCCESS else {
            throw ECError.ioError("块读取", result)
        }
        return Array(output.prefix(outputCount))
    }

    private func call(selector: UInt32, input: [UInt64]) throws -> UInt64 {
        var output: UInt64 = 0
        var outputCount: UInt32 = 1
        var input = input
        let result: kern_return_t = queue.sync {
            guard !isClosed, connection != 0 else { return KERN_FAILURE }
            return input.withUnsafeMutableBufferPointer { buffer in
                IOConnectCallScalarMethod(connection, selector,
                                          buffer.baseAddress, UInt32(buffer.count),
                                          &output, &outputCount)
            }
        }
        guard result == KERN_SUCCESS else {
            if isClosed { throw ECError.closed }
            let action: String
            switch selector {
            case 1: action = "读取"
            case 2: action = "写入"
            case 3: action = "块读取"
            default: action = "EC 操作"
            }
            throw ECError.ioError(action, result)
        }
        return output
    }
}

// MARK: - Backend selection

public enum ECBackend {
    /// Connects to the kext when possible. A missing or read-only driver is an
    /// error, never a reason to silently present fabricated readings.
    public static func connectRealOnly() -> (transport: ECTransport, info: ECInfo)? {
        do {
            return try connectReal()
        } catch {
            Log.shared.warn("\(error.localizedDescription)")
            return nil
        }
    }

    /// Explicit simulator, used only by `--simulate` and the development toggle.
    public static func simulated() -> (transport: ECTransport, info: ECInfo) {
        let simulator = SimulatedECTransport()
        let info = ECInfo(backend: simulator.backendName,
                          isSimulated: true,
                          firmwareVersion: "158KEMS1.109",
                          firmwareDate: "09/16/2021")
        return (simulator, info)
    }

    /// Connects to a real EC and verifies that firmware registers can be read.
    public static func connectReal() throws -> (transport: ECTransport, info: ECInfo) {
        let transport = try IOKitECTransport()
        do {
            let info = try ECInfo.query(transport)
            Log.shared.info("已连接 \(transport.backendName)，EC 固件 \(info.firmwareVersion) \(info.firmwareDate)")
            return (transport, info)
        } catch {
            transport.close()
            throw error
        }
    }
}
