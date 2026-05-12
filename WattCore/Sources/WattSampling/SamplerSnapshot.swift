import Foundation
import WattAnalysis
import WattModels

/// What `SamplingCoordinator` produces every tick: a fully populated
/// `SamplePoint` ready to persist plus the (system-wide) FS events rate
/// which is updated continuously between ticks.
public struct SamplerSnapshot: Sendable {
    public var point: SamplePoint
    public var generatedAt: Date

    public init(point: SamplePoint, generatedAt: Date = Date()) {
        self.point = point
        self.generatedAt = generatedAt
    }
}

public struct BatteryReading: Sendable {
    public var batteryPercent: Double
    public var isCharging: Bool
    public var instantaneousWatts: Double

    public init(batteryPercent: Double, isCharging: Bool, instantaneousWatts: Double) {
        self.batteryPercent = batteryPercent
        self.isCharging = isCharging
        self.instantaneousWatts = instantaneousWatts
    }
}

public struct HostStatsReading: Sendable {
    public var systemCPUUsage: Double
    public var memoryPressurePct: Double
    public var memoryUsedBytes: UInt64

    public init(systemCPUUsage: Double, memoryPressurePct: Double, memoryUsedBytes: UInt64) {
        self.systemCPUUsage = systemCPUUsage
        self.memoryPressurePct = memoryPressurePct
        self.memoryUsedBytes = memoryUsedBytes
    }
}

public struct ThermalReading: Sendable {
    public var rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
}

public struct SensorsReading: Sendable {
    public var fanRPM: [Double]
    public var temperatures: [String: Double]
    public init(fanRPM: [Double] = [], temperatures: [String: Double] = [:]) {
        self.fanRPM = fanRPM
        self.temperatures = temperatures
    }
}

public struct ProcessReading: Sendable {
    public var processes: [ProcessPoint]
    public init(processes: [ProcessPoint] = []) {
        self.processes = processes
    }
}
