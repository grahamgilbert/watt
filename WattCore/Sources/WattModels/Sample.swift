import Foundation
import SwiftData

@Model
public final class Sample {
    @Attribute(.unique) public var id: UUID
    @Attribute(.spotlight) public var timestamp: Date
    public var batteryPercent: Double
    public var isCharging: Bool
    public var instantaneousWatts: Double
    public var systemEnergyWatts: Double = 0
    public var systemCPUUsage: Double
    public var memoryPressurePct: Double
    public var memoryUsedBytes: UInt64
    public var thermalState: Int
    public var fanRPM: [Double]
    public var temperatures: [String: Double]
    public var fsEventsRate: Double
    @Relationship(deleteRule: .cascade, inverse: \ProcessSample.sample)
    public var processes: [ProcessSample] = []

    public init(
        id: UUID = UUID(),
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
        fsEventsRate: Double = 0
    ) {
        self.id = id
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
    }
}
