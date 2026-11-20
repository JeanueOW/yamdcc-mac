// Offline, read-only telemetry format. Deliberately independent of ECTransport,
// XML configurations, and the simulator.

import Foundation

public struct ECFanReading: Codable, Equatable, Sendable {
    public static let temperatureRange = 1...125
    public static let dutyRange = 0...150
    public static let estimatedRPMRange = 1...20_000

    public let temperatureC: Int?
    public let dutyPercent: Int?
    public let estimatedRPM: Int?

    public init(temperatureC: Int?, dutyPercent: Int?, estimatedRPM: Int?) {
        self.temperatureC = temperatureC
        self.dutyPercent = dutyPercent
        self.estimatedRPM = estimatedRPM
    }

    fileprivate var isValid: Bool {
        (temperatureC.map { Self.temperatureRange.contains($0) } ?? true) &&
        (dutyPercent.map { Self.dutyRange.contains($0) } ?? true) &&
        (estimatedRPM.map { Self.estimatedRPMRange.contains($0) } ?? true)
    }
}

public struct ECTelemetrySample: Codable, Equatable, Sendable {
    public let capturedAt: Date
    public let cpu: ECFanReading
    public let gpu: ECFanReading

    public init(capturedAt: Date, cpu: ECFanReading, gpu: ECFanReading) {
        self.capturedAt = capturedAt
        self.cpu = cpu
        self.gpu = gpu
    }

}

public enum ECTelemetryCaptureError: LocalizedError, Equatable {
    case invalidFile, tooLarge, invalidFormat, unsupportedFormat, invalidSample

    public var errorDescription: String? {
        switch self {
        case .invalidFile: return "请选取普通的 JSON 文件。"
        case .tooLarge: return "采样文件超过 16 KiB。"
        case .invalidFormat: return "无法读取采样 JSON。"
        case .unsupportedFormat: return "不支持此采样格式或版本。"
        case .invalidSample: return "采样时间或读数不符合约定。"
        }
    }
}

public enum ECTelemetryCapture {
    public static let maxBytes = 16 * 1024
    private static let version = 1
    private static let source = "msiec-acpi-probe-abi2"
    private static let earliestDate = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01 UTC

    private struct Report: Codable {
        let version: Int
        let source: String
        let sample: ECTelemetrySample
    }

    public static func encode(_ sample: ECTelemetrySample, now: Date = Date()) throws -> Data {
        try validate(sample, now: now)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Report(version: version, source: source, sample: sample))
    }

    public static func decode(_ data: Data, now: Date = Date()) throws -> ECTelemetrySample {
        guard data.count <= maxBytes else { throw ECTelemetryCaptureError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let report = try? decoder.decode(Report.self, from: data) else {
            throw ECTelemetryCaptureError.invalidFormat
        }
        guard report.version == version, report.source == source else {
            throw ECTelemetryCaptureError.unsupportedFormat
        }
        try validate(report.sample, now: now)
        return report.sample
    }

    public static func load(from url: URL) throws -> ECTelemetrySample {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw ECTelemetryCaptureError.invalidFile
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try decode(file.read(upToCount: maxBytes + 1) ?? Data())
    }

    private static func validate(_ sample: ECTelemetrySample, now: Date) throws {
        guard sample.capturedAt >= earliestDate,
              sample.capturedAt <= now.addingTimeInterval(5),
              sample.cpu.temperatureC != nil, sample.cpu.isValid, sample.gpu.isValid else {
            throw ECTelemetryCaptureError.invalidSample
        }
    }
}
