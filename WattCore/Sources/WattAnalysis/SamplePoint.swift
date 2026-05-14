import Foundation
import WattModels

/// Plain-value snapshot extracted from a `Sample` (and its `ProcessSample`
/// children) so the analysis layer never touches a SwiftData context.
public struct SamplePoint: Sendable, Hashable {
    public var timestamp: Date
    public var batteryPercent: Double
    public var isCharging: Bool
    public var instantaneousWatts: Double
    /// Aggregate `ri_energy_nj` divided by elapsed wall-clock seconds. This is
    /// what the kernel charged across all running processes during the tick.
    /// Works on AC and battery; never NaN.
    public var systemEnergyWatts: Double
    public var systemCPUUsage: Double
    public var memoryPressurePct: Double
    public var memoryUsedBytes: UInt64
    public var thermalState: Int
    public var fanRPM: [Double]
    public var temperatures: [String: Double]
    public var fsEventsRate: Double
    public var processes: [ProcessPoint]

    public init(
        timestamp: Date,
        batteryPercent: Double,
        isCharging: Bool,
        instantaneousWatts: Double,
        systemEnergyWatts: Double = 0,
        systemCPUUsage: Double,
        memoryPressurePct: Double,
        memoryUsedBytes: UInt64,
        thermalState: Int,
        fanRPM: [Double] = [],
        temperatures: [String: Double] = [:],
        fsEventsRate: Double = 0,
        processes: [ProcessPoint] = []
    ) {
        self.timestamp = timestamp
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.instantaneousWatts = instantaneousWatts
        self.systemEnergyWatts = systemEnergyWatts
        self.systemCPUUsage = systemCPUUsage
        self.memoryPressurePct = memoryPressurePct
        self.memoryUsedBytes = memoryUsedBytes
        self.thermalState = thermalState
        self.fanRPM = fanRPM
        self.temperatures = temperatures
        self.fsEventsRate = fsEventsRate
        self.processes = processes
    }

    public static func from(_ sample: Sample) -> SamplePoint {
        SamplePoint(
            timestamp: sample.timestamp,
            batteryPercent: sample.batteryPercent,
            isCharging: sample.isCharging,
            instantaneousWatts: sample.instantaneousWatts,
            systemEnergyWatts: sample.systemEnergyWatts,
            systemCPUUsage: sample.systemCPUUsage,
            memoryPressurePct: sample.memoryPressurePct,
            memoryUsedBytes: sample.memoryUsedBytes,
            thermalState: sample.thermalState,
            fanRPM: sample.fanRPM,
            temperatures: sample.temperatures,
            fsEventsRate: sample.fsEventsRate,
            processes: sample.processes.map(ProcessPoint.from)
        )
    }

    public var maxFanRPM: Double { fanRPM.max() ?? 0 }
    public var hottestSensor: (key: String, value: Double)? {
        temperatures.max(by: { $0.value < $1.value })
            .map { (key: $0.key, value: $0.value) }
    }
}

public struct ProcessPoint: Sendable, Hashable {
    public var pid: Int32
    public var name: String
    public var bundleID: String?
    /// Absolute executable path from `proc_pidpath`. Used by the agent
    /// matcher to detect processes that live in /Library/SystemExtensions
    /// or whose path matches a LaunchDaemon's Program/ProgramArguments.
    public var executablePath: String?
    public var cpuTimeDelta: Double
    public var energyNanojoulesDelta: UInt64
    public var billedEnergyDelta: UInt64
    public var diskReadBytesDelta: UInt64
    public var diskWriteBytesDelta: UInt64
    public var pageinsDelta: UInt64
    public var residentBytes: UInt64
    /// Apple's composite energy impact score from powermetrics (same as Activity Monitor).
    public var energyImpact: Double

    public init(
        pid: Int32,
        name: String,
        bundleID: String? = nil,
        executablePath: String? = nil,
        cpuTimeDelta: Double,
        energyNanojoulesDelta: UInt64,
        billedEnergyDelta: UInt64,
        diskReadBytesDelta: UInt64,
        diskWriteBytesDelta: UInt64,
        pageinsDelta: UInt64,
        residentBytes: UInt64,
        energyImpact: Double = 0
    ) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.executablePath = executablePath
        self.cpuTimeDelta = cpuTimeDelta
        self.energyNanojoulesDelta = energyNanojoulesDelta
        self.billedEnergyDelta = billedEnergyDelta
        self.diskReadBytesDelta = diskReadBytesDelta
        self.diskWriteBytesDelta = diskWriteBytesDelta
        self.pageinsDelta = pageinsDelta
        self.residentBytes = residentBytes
        self.energyImpact = energyImpact
    }

    public static func from(_ ps: ProcessSample) -> ProcessPoint {
        ProcessPoint(
            pid: ps.pid,
            name: ps.name,
            bundleID: ps.bundleID,
            executablePath: ps.executablePath,
            cpuTimeDelta: ps.cpuTimeDelta,
            energyNanojoulesDelta: ps.energyNanojoulesDelta,
            billedEnergyDelta: ps.billedEnergyDelta,
            diskReadBytesDelta: ps.diskReadBytesDelta,
            diskWriteBytesDelta: ps.diskWriteBytesDelta,
            pageinsDelta: ps.pageinsDelta,
            residentBytes: ps.residentBytes,
            energyImpact: ps.energyImpact
        )
    }
}

public struct UserEventPoint: Sendable, Hashable {
    public var timestamp: Date
    public var kind: UserEventKind
    public var bundleID: String?
    public var appName: String?
    public var detail: String?

    public init(
        timestamp: Date,
        kind: UserEventKind,
        bundleID: String? = nil,
        appName: String? = nil,
        detail: String? = nil
    ) {
        self.timestamp = timestamp
        self.kind = kind
        self.bundleID = bundleID
        self.appName = appName
        self.detail = detail
    }

    public static func from(_ event: UserEvent) -> UserEventPoint {
        UserEventPoint(
            timestamp: event.timestamp,
            kind: event.kind,
            bundleID: event.bundleID,
            appName: event.appName,
            detail: event.detail
        )
    }
}
