// Monitor.swift
// Polls the EC in the background and publishes a rolling history for charts.

import Foundation
import Combine

public struct MonitorSample: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let date: Date
    public let cpuTemp: Int
    public let gpuTemp: Int
    public let cpuRPM: Int
    public let gpuRPM: Int
    public let cpuSpeed: Int
    public let gpuSpeed: Int

    public init(id: UUID = UUID(), date: Date = Date(),
                cpuTemp: Int, gpuTemp: Int, cpuRPM: Int, gpuRPM: Int,
                cpuSpeed: Int, gpuSpeed: Int) {
        self.id = id
        self.date = date
        self.cpuTemp = cpuTemp
        self.gpuTemp = gpuTemp
        self.cpuRPM = cpuRPM
        self.gpuRPM = gpuRPM
        self.cpuSpeed = cpuSpeed
        self.gpuSpeed = gpuSpeed
    }
}

@MainActor
public final class Monitor: ObservableObject {
    @Published public private(set) var state: DeviceState?
    @Published public private(set) var history: [MonitorSample] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var lastError: String?

    public var interval: TimeInterval {
        didSet {
            SettingsStore.shared.update { $0.pollInterval = max(0.5, min(5, interval)) }
            if isRunning { restartTimer() }
        }
    }

    private var controller: FanController
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.yamdcc.mac.monitor", qos: .utility)
    private let maxSamples = 240

    public init(controller: FanController, interval: TimeInterval = 1.0) {
        self.controller = controller
        self.interval = interval
    }

    public func updateController(_ controller: FanController) {
        self.controller = controller
        pollNow()
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        restartTimer()
        pollNow()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        isRunning = false
    }

    private func restartTimer() {
        timer?.cancel()
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(120))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            do {
                let state = try self.controller.readState()
                Task { @MainActor in self.ingest(state) }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in self.lastError = message }
            }
        }
        timer = source
        source.resume()
    }

    public func pollNow() {
        do {
            ingest(try controller.readState())
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func ingest(_ state: DeviceState) {
        self.state = state
        lastError = nil
        let sample = MonitorSample(
            date: state.timestamp,
            cpuTemp: state.temps.indices.contains(0) ? state.temps[0] : 0,
            gpuTemp: state.temps.indices.contains(1) ? state.temps[1] : 0,
            cpuRPM: state.rpms.indices.contains(0) ? state.rpms[0] : 0,
            gpuRPM: state.rpms.indices.contains(1) ? state.rpms[1] : 0,
            cpuSpeed: state.speeds.indices.contains(0) ? state.speeds[0] : 0,
            gpuSpeed: state.speeds.indices.contains(1) ? state.speeds[1] : 0
        )
        history.append(sample)
        if history.count > maxSamples {
            history.removeFirst(history.count - maxSamples)
        }
    }

    public func clearHistory() {
        history.removeAll()
    }
}
