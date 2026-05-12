import Foundation
import Observation
import SwiftData
import WattAnalysis
import WattModels

/// Owns the periodic tick that drives every sampler. Exposes an `@Observable`
/// `snapshot` that the menubar UI binds against.
@MainActor
@Observable
public final class SamplingCoordinator {
    public struct Snapshot: Sendable, Equatable {
        public var batteryPercent: Double
        public var isCharging: Bool
        public var drainRatePctPerHour: Double
        /// Aggregate kernel-billed energy for all running processes during
        /// the most recent tick, in joules per second. Works identically on
        /// battery and AC — it counts what the system *did*, not what the
        /// battery lost. ~12 W is typical idle, > 30 W is heavy load.
        public var systemEnergyWatts: Double
        public var systemCPUUsage: Double
        public var memoryPressurePct: Double
        public var maxFanRPM: Double
        public var hottestSensorCelsius: Double?
        public var thermalState: Int
        public var fsEventsRate: Double
        public var lastTick: Date?
        public var inEpisode: Bool

        public static let empty = Snapshot(
            batteryPercent: .nan,
            isCharging: false,
            drainRatePctPerHour: 0,
            systemEnergyWatts: 0,
            systemCPUUsage: 0,
            memoryPressurePct: 0,
            maxFanRPM: 0,
            hottestSensorCelsius: nil,
            thermalState: 0,
            fsEventsRate: 0,
            lastTick: nil,
            inEpisode: false
        )
    }

    public var snapshot: Snapshot = .empty
    public private(set) var samplingInterval: Duration = .seconds(5)

    private let battery: BatterySampler
    private let host: HostStatsSampler
    private let thermal: ThermalSampler
    private let sensors: AppleSensorsSampler
    private let proc: ProcSampler
    private let fsEvents: FSEventsSampler
    private var userEvents: UserEventRecorder!
    private let writer: SamplingWriter
    private var detector = EpisodeDetector()
    private var openEpisodeID: PersistentIdentifier?
    private var lastTickTimestamp: Date?

    private var tickTask: Task<Void, Never>?

    public init(
        writer: SamplingWriter,
        battery: BatterySampler = BatterySampler(),
        host: HostStatsSampler = HostStatsSampler(),
        thermal: ThermalSampler = ThermalSampler(),
        sensors: AppleSensorsSampler = AppleSensorsSampler(),
        proc: ProcSampler = ProcSampler(),
        fsEvents: FSEventsSampler = FSEventsSampler()
    ) {
        self.writer = writer
        self.battery = battery
        self.host = host
        self.thermal = thermal
        self.sensors = sensors
        self.proc = proc
        self.fsEvents = fsEvents
        let writerRef = writer
        self.userEvents = UserEventRecorder { event in
            Task { try? await writerRef.writeUserEvent(event) }
        }
    }

    public func start() {
        guard tickTask == nil else { return }
        fsEvents.start()
        userEvents.start()
        tickTask = Task { [weak self] in
            guard let self else { return }
            // First tick is immediate so the UI has data right away.
            await self.tickOnce()
            while !Task.isCancelled {
                let interval = await MainActor.run { self.samplingInterval }
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                await self.tickOnce()
            }
        }
    }

    public func stop() {
        tickTask?.cancel()
        tickTask = nil
        fsEvents.stop()
        userEvents.stop()
    }

    public func recordUserNote(_ text: String) {
        userEvents.recordNote(text)
    }

    public func tickOnce() async {
        async let batteryR = battery.read()
        async let hostR = host.read()
        async let thermalR = thermal.read()
        async let sensorsR = sensors.read()
        async let procR = proc.read()
        let battery = await batteryR
        let host = await hostR
        let thermal = await thermalR
        let sensors = await sensorsR
        let proc = await procR
        let fsRate = fsEvents.consumeRate()

        let point = SamplePoint(
            timestamp: Date(),
            batteryPercent: battery.batteryPercent,
            isCharging: battery.isCharging,
            instantaneousWatts: battery.instantaneousWatts,
            systemCPUUsage: host.systemCPUUsage,
            memoryPressurePct: host.memoryPressurePct,
            memoryUsedBytes: host.memoryUsedBytes,
            thermalState: thermal.rawValue,
            fanRPM: sensors.fanRPM,
            temperatures: sensors.temperatures,
            fsEventsRate: fsRate,
            processes: proc.processes
        )
        try? await writer.writeSample(point: point)
        await reactToEpisodes(point: point)
        snapshot = makeSnapshot(point: point)
    }

    private func reactToEpisodes(point: SamplePoint) async {
        let event = detector.feed(point)
        switch event {
        case .started(let at, let pct):
            do {
                let id = try await writer.writeEpisode(start: at, startPercent: pct)
                openEpisodeID = id
            } catch {
                openEpisodeID = nil
            }
        case .ended(let at, let pct, let peakDrain, let avgThermal):
            if let id = openEpisodeID {
                try? await writer.updateEpisode(
                    id: id,
                    endedAt: at,
                    endPercent: pct,
                    peakDrainRate: peakDrain,
                    avgThermalState: avgThermal
                )
            }
            openEpisodeID = nil
        case .noChange:
            break
        }
    }

    private func makeSnapshot(point: SamplePoint) -> Snapshot {
        let drainRate = detector.currentDrainRatePctPerHour()
        let watts = systemEnergyWatts(for: point)
        return Snapshot(
            batteryPercent: point.batteryPercent,
            isCharging: point.isCharging,
            drainRatePctPerHour: max(drainRate, 0),
            systemEnergyWatts: watts,
            systemCPUUsage: point.systemCPUUsage,
            memoryPressurePct: point.memoryPressurePct,
            maxFanRPM: point.maxFanRPM,
            hottestSensorCelsius: point.hottestSensor?.value,
            thermalState: point.thermalState,
            fsEventsRate: point.fsEventsRate,
            lastTick: point.timestamp,
            inEpisode: detector.inEpisode
        )
    }

    /// Sums per-process kernel-billed energy across the current tick and
    /// divides by the seconds since the previous tick to get watts.
    /// `ri_energy_nj` is the field the kernel uses to charge processes for
    /// power accounting and is correct on AC and battery alike.
    private func systemEnergyWatts(for point: SamplePoint) -> Double {
        let totalNanojoules = point.processes.reduce(into: UInt64(0)) { acc, proc in
            acc &+= proc.energyNanojoulesDelta
        }
        let elapsed: TimeInterval = {
            guard let prior = lastTickTimestamp else {
                let comps = samplingInterval.components
                return TimeInterval(comps.seconds) + TimeInterval(comps.attoseconds) / 1e18
            }
            return max(point.timestamp.timeIntervalSince(prior), 0.5)
        }()
        lastTickTimestamp = point.timestamp
        // 1 W = 1 J/s = 1e9 nJ/s.
        return Double(totalNanojoules) / 1_000_000_000.0 / elapsed
    }

    public func setSamplingInterval(_ duration: Duration) {
        samplingInterval = duration
    }
}
