import Foundation
import Observation
import SwiftData
import WattAnalysis
import WattModels
import os.log

private let logger = Logger(subsystem: "com.grahamgilbert.watt", category: "sampling")

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
    public private(set) var samplingInterval: Duration = .seconds(30)

    /// Called on the main actor whenever an episode is written to the store
    /// (on end, or after the interim timeout). The identifier is the episode's
    /// persistent ID — pass it to ReportCoordinator.generateReport(for:).
    public var onEpisodeReady: (@MainActor (PersistentIdentifier) -> Void)?

    /// How long an open episode can run before we generate an interim report
    /// without waiting for it to end. Default 15 minutes.
    public var interimReportInterval: TimeInterval = 15 * 60

    private let battery: BatterySampler
    private let host: HostStatsSampler
    private let thermal: ThermalSampler
    private let sensors: AppleSensorsSampler
    private let proc: ProcSampler
    private let helperProc: HelperProcSampler
    private let fsEvents: FSEventsSampler
    private let power: PowerSampler
    private var userEvents: UserEventRecorder!
    private let writer: SamplingWriter
    private var detector = EpisodeDetector()
    private var openEpisodeID: PersistentIdentifier?
    private var openEpisodeStart: Date?
    private var lastInterimReportDate: Date?
    private var lastTickTimestamp: Date?
    private var fastTickTask: Task<Void, Never>?
    private var fastTickClients: Int = 0

    private var tickTask: Task<Void, Never>?

    public init(
        writer: SamplingWriter,
        battery: BatterySampler = BatterySampler(),
        host: HostStatsSampler = HostStatsSampler(),
        thermal: ThermalSampler = ThermalSampler(),
        sensors: AppleSensorsSampler = AppleSensorsSampler(),
        proc: ProcSampler = ProcSampler(),
        helperProc: HelperProcSampler = HelperProcSampler(),
        fsEvents: FSEventsSampler = FSEventsSampler(),
        power: PowerSampler = PowerSampler()
    ) {
        self.writer = writer
        self.battery = battery
        self.host = host
        self.thermal = thermal
        self.sensors = sensors
        self.proc = proc
        self.helperProc = helperProc
        self.fsEvents = fsEvents
        self.power = power
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
            // Close any episodes left open from a prior session before the
            // detector starts; otherwise the UI shows them as perpetually ongoing.
            try? await writer.closeOrphanedEpisodes()
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

    /// Activates a 1 s fast-refresh loop that updates the snapshot's
    /// battery/CPU/memory/thermal/fan/temperature fields without paying for
    /// a full per-process scan. Used by the report window so the user sees
    /// numbers move in real time. Reference-counted so multiple views can
    /// activate it without stepping on each other.
    public func activateFastUpdates() {
        fastTickClients += 1
        guard fastTickTask == nil else { return }
        fastTickTask = Task { [weak self] in
            // Fire immediately so the window shows live data without a 1s wait.
            await self?.fastTickOnce()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                await self?.fastTickOnce()
            }
        }
    }

    public func deactivateFastUpdates() {
        guard fastTickClients > 0 else { return }
        fastTickClients -= 1
        if fastTickClients == 0 {
            fastTickTask?.cancel()
            fastTickTask = nil
        }
    }

    private func fastTickOnce() async {
        async let batteryR = battery.read()
        async let hostR = host.read()
        async let thermalR = thermal.read()
        async let sensorsR = sensors.read()
        let battery = await batteryR
        let host = await hostR
        let thermal = await thermalR
        let sensors = await sensorsR
        var snap = snapshot
        snap.batteryPercent = battery.batteryPercent
        snap.isCharging = battery.isCharging
        snap.systemCPUUsage = host.systemCPUUsage
        snap.memoryPressurePct = host.memoryPressurePct
        snap.thermalState = thermal.rawValue
        snap.maxFanRPM = sensors.fanRPM.max() ?? snap.maxFanRPM
        snap.hottestSensorCelsius = sensors.temperatures.values.max() ?? snap.hottestSensorCelsius
        snap.lastTick = Date()
        snapshot = snap
    }

    public func tickOnce() async {
        async let batteryR = battery.read()
        async let hostR = host.read()
        async let thermalR = thermal.read()
        async let sensorsR = sensors.read()
        async let procR = proc.read()
        async let helperProcR = helperProc.read()
        async let powerR = power.read()
        let battery = await batteryR
        let host = await hostR
        let thermal = await thermalR
        let sensors = await sensorsR
        let proc = await procR
        let helperProcesses = await helperProcR
        let powerReading = await powerR
        let fsRate = fsEvents.consumeRate()

        // Merge: helper data wins for any pid the unprivileged ProcSampler
        // can't see (Endpoint Security extensions like Falcon). For pids
        // both report on, prefer the unprivileged reading because its
        // bundleID resolution is more accurate.
        let merged = mergeProcessReadings(
            unprivileged: proc.processes,
            helper: helperProcesses
        )

        let now = Date()
        let watts: Double
        if powerReading.available {
            watts = powerReading.totalWatts
        } else {
            // Fallback: IOReport not available. Use sum of powermetrics
            // energy_impact scores as a proxy. At idle the total is ~200-400;
            // a heavy workload like CrowdStrike scanning sits at 2000+.
            // NOTE: acHighEnergyThresholdMeanWatts must be recalibrated to
            // ~800 if this path is active (energy_impact units ≠ watts).
            let totalEnergyImpact = merged.reduce(0.0) { $0 + $1.energyImpact }
            watts = totalEnergyImpact > 0
                ? totalEnergyImpact
                : computeFallbackWatts(at: now, processes: merged)
        }

        // Only persist processes with non-zero activity this tick, capped at
        // the top 50 by score. Security agents are always included regardless
        // of rank. Idle processes (all-zero deltas) generate I/O for no value.
        let activeProcesses = trimmedProcesses(merged, maxCount: 50)

        let point = SamplePoint(
            timestamp: now,
            batteryPercent: battery.batteryPercent,
            isCharging: battery.isCharging,
            instantaneousWatts: battery.instantaneousWatts,
            systemEnergyWatts: watts,
            systemCPUUsage: host.systemCPUUsage,
            memoryPressurePct: host.memoryPressurePct,
            memoryUsedBytes: host.memoryUsedBytes,
            thermalState: thermal.rawValue,
            fanRPM: sensors.fanRPM,
            temperatures: sensors.temperatures,
            fsEventsRate: fsRate,
            processes: activeProcesses
        )

        logger.debug(
            "tick: battery=\(String(format: "%.1f", battery.batteryPercent))% isCharging=\(battery.isCharging) watts=\(String(format: "%.2f", watts)) ioreportAvailable=\(powerReading.available) cpu=\(String(format: "%.1f", host.systemCPUUsage * 100))% processes=\(merged.count) windowSaturated=\(self.detector.windowIsSaturated()) inEpisode=\(self.detector.inEpisode)"
        )
        if !powerReading.available {
            let totalEI = merged.reduce(0.0) { $0 + $1.energyImpact }
            logger.debug("tick: ioreport unavailable — energyImpact sum=\(totalEI) fallback watts=\(watts)")
        }

        try? await writer.writeSample(point: point)
        await reactToEpisodes(point: point)
        snapshot = makeSnapshot(point: point)
    }

    private func reactToEpisodes(point: SamplePoint) async {
        let windowDrop = detector.windowDrainPctTotal()
        let windowMean = detector.windowMeanWatts()
        logger.debug(
            "detector: windowSaturated=\(self.detector.windowIsSaturated()) windowDrop=\(String(format: "%.2f", windowDrop))% windowMeanWatts=\(String(format: "%.2f", windowMean)) inEpisode=\(self.detector.inEpisode)"
        )
        let event = detector.feed(point)
        switch event {
        case .started(let at, let pct, let trigger):
            logger.info("episode STARTED at=\(at) pct=\(pct) trigger=\(String(describing: trigger))")
            do {
                let id = try await writer.writeEpisode(
                    start: at,
                    startPercent: pct,
                    trigger: trigger
                )
                openEpisodeID = id
                openEpisodeStart = at
                lastInterimReportDate = nil
            } catch {
                logger.error("episode STARTED but failed to write: \(error)")
                openEpisodeID = nil
                openEpisodeStart = nil
            }
        case .ended(let at, let pct, let peakDrain, let peakWatts, let avgThermal, _):
            logger.info("episode ENDED at=\(at) pct=\(pct) peakDrain=\(peakDrain) peakWatts=\(peakWatts)")
            if let id = openEpisodeID {
                try? await writer.updateEpisode(
                    id: id,
                    endedAt: at,
                    endPercent: pct,
                    peakDrainRate: peakDrain,
                    peakSystemEnergyWatts: peakWatts,
                    avgThermalState: avgThermal
                )
                fireEpisodeReady(id)
            }
            openEpisodeID = nil
            openEpisodeStart = nil
            lastInterimReportDate = nil
        case .noChange:
            // Fire an interim report if the episode has been open long enough
            // and we haven't generated one recently.
            if let id = openEpisodeID, let start = openEpisodeStart {
                let now = point.timestamp
                let elapsed = now.timeIntervalSince(start)
                let sinceLastInterim = now.timeIntervalSince(lastInterimReportDate ?? .distantPast)
                if elapsed >= interimReportInterval && sinceLastInterim >= interimReportInterval {
                    logger.info("episode interim report after \(Int(elapsed))s")
                    lastInterimReportDate = now
                    fireEpisodeReady(id)
                }
            }
            break
        }
    }

    private func makeSnapshot(point: SamplePoint) -> Snapshot {
        let drainRate = detector.currentDrainRatePctPerHour()
        return Snapshot(
            batteryPercent: point.batteryPercent,
            isCharging: point.isCharging,
            drainRatePctPerHour: max(drainRate, 0),
            systemEnergyWatts: point.systemEnergyWatts,
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

    private func mergeProcessReadings(
        unprivileged: [ProcessPoint],
        helper: [ProcessPoint]
    ) -> [ProcessPoint] {
        _mergeProcessReadings(unprivileged: unprivileged, helper: helper)
    }

    /// Drops idle processes and caps the list at `maxCount`, always keeping
    /// security agents regardless of rank. This bounds per-tick disk I/O from
    /// `ProcessSample` inserts without losing the processes that matter.
    private func trimmedProcesses(_ processes: [ProcessPoint], maxCount: Int) -> [ProcessPoint] {
        let active = processes.filter {
            $0.energyNanojoulesDelta > 0 || $0.cpuTimeDelta > 0
                || $0.diskReadBytesDelta > 0 || $0.diskWriteBytesDelta > 0
                || $0.energyImpact > 0
        }
        let sorted = active.sorted {
            let scoreA = Double($0.energyNanojoulesDelta) + $0.cpuTimeDelta * 1e9
                + Double($0.diskReadBytesDelta &+ $0.diskWriteBytesDelta)
            let scoreB = Double($1.energyNanojoulesDelta) + $1.cpuTimeDelta * 1e9
                + Double($1.diskReadBytesDelta &+ $1.diskWriteBytesDelta)
            return scoreA > scoreB
        }
        var kept = Array(sorted.prefix(maxCount))
        // Always include security agents even if they fell outside top-N.
        for proc in active where !kept.contains(where: { $0.pid == proc.pid }) {
            if SecurityAgents.classify(
                name: proc.name,
                bundleID: proc.bundleID,
                executablePath: proc.executablePath
            ).isAgent {
                kept.append(proc)
            }
        }
        return kept
    }

    /// Fallback used only when IOReport is unavailable (extremely unusual on
    /// macOS 26). Sums per-process kernel-billed energy and divides by the
    /// elapsed wall-clock interval. Significantly under-counts true wall
    /// power (no GPU/display/idle-floor accounting) but better than zero.
    private func computeFallbackWatts(at timestamp: Date, processes: [ProcessPoint]) -> Double {
        let totalNanojoules = processes.reduce(into: UInt64(0)) { acc, proc in
            acc &+= proc.energyNanojoulesDelta
        }
        let elapsed: TimeInterval = {
            guard let prior = lastTickTimestamp else {
                let comps = samplingInterval.components
                return TimeInterval(comps.seconds) + TimeInterval(comps.attoseconds) / 1e18
            }
            return max(timestamp.timeIntervalSince(prior), 0.5)
        }()
        lastTickTimestamp = timestamp
        return Double(totalNanojoules) / 1_000_000_000.0 / elapsed
    }

    public func setSamplingInterval(_ duration: Duration) {
        samplingInterval = duration
    }

    private func fireEpisodeReady(_ id: PersistentIdentifier) {
        guard let callback = onEpisodeReady else { return }
        Task { @MainActor in callback(id) }
    }
}

// MARK: - Free function (internal so unit tests can reach it via @testable)

/// Merges process readings from two samplers.
///
/// The unprivileged `ProcSampler` can enumerate all pids via `proc_listallpids`
/// but gets EPERM from `proc_pid_rusage` for root-owned processes — it emits
/// all-zero delta records for those pids. The helper runs as root and has real
/// accounting data for every pid.
///
/// Rule: if the unprivileged record has non-zero deltas it wins (better bundleID
/// resolution via NSRunningApplication). If it's all-zero the helper's record
/// wins. If only one sampler saw the pid, that reading is kept.
func _mergeProcessReadings(
    unprivileged: [ProcessPoint],
    helper: [ProcessPoint]
) -> [ProcessPoint] {
    var byPid: [Int32: ProcessPoint] = [:]
    for point in helper {
        byPid[point.pid] = point
    }
    for point in unprivileged {
        let hasData = point.cpuTimeDelta > 0 || point.energyNanojoulesDelta > 0
            || point.diskReadBytesDelta > 0 || point.diskWriteBytesDelta > 0
            || point.energyImpact > 0
        if hasData {
            byPid[point.pid] = point
        } else if byPid[point.pid] == nil {
            byPid[point.pid] = point
        }
        // else: helper has real data, unprivileged is all-zero EPERM stub — keep helper's.
    }
    return Array(byPid.values)
}
