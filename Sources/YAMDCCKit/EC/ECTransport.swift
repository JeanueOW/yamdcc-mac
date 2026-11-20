// ECTransport.swift
// Abstraction over the MSI embedded controller.

import Foundation

public enum ECError: LocalizedError {
    case driverUnavailable(String)
    case timeout(String)
    case ioError(String, Int32)
    case unsupported(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .driverUnavailable(let detail):
            return "EC 驱动不可用：\(detail)"
        case .timeout(let operation):
            return "EC 操作超时：\(operation)"
        case .ioError(let operation, let code):
            return "EC \(operation) 失败（0x\(String(UInt32(bitPattern: code), radix: 16))）"
        case .unsupported(let feature):
            return "当前 EC 不支持：\(feature)"
        case .closed:
            return "EC 连接已关闭"
        }
    }

    /// Whether falling back to the simulator is reasonable.
    public var allowsSimulationFallback: Bool {
        if case .unsupported = self { return false }
        return true
    }
}

public protocol ECTransport: AnyObject {
    var backendName: String { get }
    var isSimulated: Bool { get }
    var details: [String: String] { get }
    func read(_ register: UInt8) throws -> UInt8
    func write(_ register: UInt8, value: UInt8) throws
    func close()
}

public extension ECTransport {
    func readWord(_ register: UInt8, bigEndian: Bool) throws -> UInt16 {
        let first = UInt16(try read(register))
        let second = UInt16(try read(register &+ 1))
        return bigEndian ? (first << 8) | second : (second << 8) | first
    }

    func readBlock(_ register: UInt8, length: Int) throws -> [UInt8] {
        guard length > 0, Int(register) + length <= 256 else {
            throw ECError.unsupported("读取范围超出 EC 空间")
        }
        return try (0..<length).map { try read(register &+ UInt8($0)) }
    }

    func readString(_ register: UInt8, length: Int) throws -> String {
        let bytes = try readBlock(register, length: length)
        let trimmed = bytes.prefix { $0 != 0 }
        return String(bytes: trimmed, encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

public struct ECInfo: Equatable, Sendable {
    public var backend: String
    public var isSimulated: Bool
    public var firmwareVersion: String
    public var firmwareDate: String

    public init(backend: String, isSimulated: Bool,
                firmwareVersion: String = "", firmwareDate: String = "") {
        self.backend = backend
        self.isSimulated = isSimulated
        self.firmwareVersion = firmwareVersion
        self.firmwareDate = firmwareDate
    }

    public static func query(_ transport: ECTransport) throws -> ECInfo {
        let version = try transport.readString(0xA0, length: 12)
        guard !version.isEmpty else {
            throw ECError.driverUnavailable("未读到有效的 MSI EC 固件版本")
        }
        let date = (try? transport.readString(0xAC, length: 16)) ?? ""
        return ECInfo(backend: transport.backendName,
                      isSimulated: transport.isSimulated,
                      firmwareVersion: version,
                      firmwareDate: date)
    }
}
