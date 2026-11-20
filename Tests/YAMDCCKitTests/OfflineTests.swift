import Foundation
import Testing
import YAMDCCKit

private let date = Date(timeIntervalSince1970: 1_795_158_310)
private let sample = ECTelemetrySample(
    capturedAt: date,
    cpu: ECFanReading(temperatureC: 60, dutyPercent: 60, estimatedRPM: 3824),
    gpu: ECFanReading(temperatureC: 49, dutyPercent: 48, estimatedRPM: 2879)
)

@Test func bundledDefaultIsTheVectorTemplate() throws {
    let config = try #require(ConfigStore().loadPreferred(activePath: nil))
    #expect(config.sourceURL?.lastPathComponent == ConfigStore.defaultConfigFileName)
    #expect(config.layout.model == "Vector 16 HX A14VHG")
    #expect(config.layout.author == "Adam (KamykJr)")
    #expect(config.layout.offsetDT)
    #expect(config.fanCount == 2)
    #expect(config.fans.map { $0.profiles.map(\.name) } == [["Default", "Silent"], ["Default", "Silent"]])
    #expect(config.fans.map { $0.current?.thresholds.last?.speed } == [103, 104])
    #expect(config.validationProblems().isEmpty)
}

@Test func explicitSelectionWinsAndAnInvalidPathFallsBack() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let saved = root.appendingPathComponent("Resources/Configs/MSI-GF63-Thin-11SC.xml")
    let store = ConfigStore()
    #expect(store.loadPreferred(activePath: saved.path)?.sourceURL == saved)
    let missing = saved.appendingPathExtension("missing")
    #expect(store.loadPreferred(activePath: missing.path)?.sourceURL?.lastPathComponent == ConfigStore.defaultConfigFileName)
}

@Test func extrasDefaultsSurviveSaveAndReload() throws {
    let config0 = try #require(ConfigStore().loadPreferred(activePath: nil))
    var config = config0
    let source = try #require(config.sourceURL)
    let temp = FileManager.default.temporaryDirectory
        .appendingPathComponent("yamdcc-extras-\(UUID().uuidString).xml")
    defer { try? FileManager.default.removeItem(at: temp) }

    config.settings.perfMode = 1
    config.settings.fanMode = 2
    config.fans[0].profiles[0].perfMode = 1
    _ = source
    try ConfigCodec.save(config, to: temp)

    let reloaded = try ConfigCodec.load(from: temp)
    #expect(reloaded.settings.perfMode == 1)
    #expect(reloaded.settings.fanMode == 2)
    #expect(reloaded.fans[0].current?.perfMode == 1)
}

@Test func telemetryRoundTripsAndDoesNotInventMissingMetrics() throws {
    let data = try ECTelemetryCapture.encode(sample, now: date)
    #expect(try ECTelemetryCapture.decode(data, now: date) == sample)
    let emptyGPU = ECFanReading(temperatureC: nil, dutyPercent: nil, estimatedRPM: nil)
    let partial = ECTelemetrySample(capturedAt: date, cpu: sample.cpu, gpu: emptyGPU)
    let partialData = try ECTelemetryCapture.encode(partial, now: date)
    #expect(try ECTelemetryCapture.decode(partialData, now: date).gpu == emptyGPU)
}

@Test func badCaptureHeadersAndSizesAreRejected() throws {
    let encoded = try ECTelemetryCapture.encode(sample, now: date)
    let original = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    let changes: [String: Any] = ["source": "simulator", "version": 2]
    for (key, value) in changes {
        var invalid = original
        invalid[key] = value
        let data = try JSONSerialization.data(withJSONObject: invalid)
        #expect(throws: ECTelemetryCaptureError.unsupportedFormat) {
            try ECTelemetryCapture.decode(data, now: date)
        }
    }
    #expect(throws: ECTelemetryCaptureError.tooLarge) {
        try ECTelemetryCapture.decode(Data(repeating: 0, count: ECTelemetryCapture.maxBytes + 1), now: date)
    }
    #expect(throws: ECTelemetryCaptureError.invalidFormat) {
        try ECTelemetryCapture.decode(Data(), now: date)
    }
}

@Test func implausibleReadingsAndTimestampsAreRejected() throws {
    let noCPU = ECFanReading(temperatureC: nil, dutyPercent: 60, estimatedRPM: 3824)
    let invalidDuty = ECFanReading(temperatureC: 60, dutyPercent: 151, estimatedRPM: 3824)
    for cpu in [noCPU, invalidDuty] {
        let bad = ECTelemetrySample(capturedAt: date, cpu: cpu, gpu: sample.gpu)
        #expect(throws: ECTelemetryCaptureError.invalidSample) {
            try ECTelemetryCapture.encode(bad, now: date)
        }
    }
    let data = try ECTelemetryCapture.encode(sample, now: date)
    #expect(throws: ECTelemetryCaptureError.invalidSample) {
        try ECTelemetryCapture.decode(data, now: date.addingTimeInterval(-6))
    }
}

@Test func loadingCaptureFilesIsBounded() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    defer { try? FileManager.default.removeItem(at: url) }
    let current = ECTelemetrySample(capturedAt: Date(), cpu: sample.cpu, gpu: sample.gpu)
    try ECTelemetryCapture.encode(current).write(to: url)
    #expect(try ECTelemetryCapture.load(from: url).cpu == sample.cpu)
    try Data(repeating: 0, count: ECTelemetryCapture.maxBytes + 1).write(to: url)
    #expect(throws: ECTelemetryCaptureError.tooLarge) { try ECTelemetryCapture.load(from: url) }
    #expect(throws: ECTelemetryCaptureError.invalidFile) {
        try ECTelemetryCapture.load(from: FileManager.default.temporaryDirectory)
    }
}
