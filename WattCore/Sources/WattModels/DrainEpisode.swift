import Foundation
import SwiftData

public enum DrainEpisodeTrigger: String, Codable, Sendable, CaseIterable {
    /// Sustained battery drain while unplugged.
    case batteryDrain
    /// Sustained high system wattage while plugged in.
    case acHighEnergy
    /// Manually requested by the user (e.g. "look back at the last 30 min").
    /// The episode bounds reflect the lookback window, not a detector
    /// transition.
    case userTriggered
}

@Model
public final class DrainEpisode {
    @Attribute(.unique) public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var startPercent: Double
    public var endPercent: Double
    public var peakDrainRatePctPerHour: Double
    public var avgThermalState: Int
    /// Persisted as the rawValue of `DrainEpisodeTrigger`. Default is the
    /// historical value `batteryDrain` so existing rows migrate cleanly.
    public var triggerRaw: String = DrainEpisodeTrigger.batteryDrain.rawValue
    public var peakSystemEnergyWatts: Double = 0
    public var topSuspectsJSON: Data
    @Relationship(deleteRule: .nullify, inverse: \Report.episode)
    public var reports: [Report] = []

    public var trigger: DrainEpisodeTrigger {
        get { DrainEpisodeTrigger(rawValue: triggerRaw) ?? .batteryDrain }
        set { triggerRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date? = nil,
        startPercent: Double,
        endPercent: Double,
        peakDrainRatePctPerHour: Double,
        avgThermalState: Int,
        trigger: DrainEpisodeTrigger = .batteryDrain,
        peakSystemEnergyWatts: Double = 0,
        topSuspectsJSON: Data = Data()
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.startPercent = startPercent
        self.endPercent = endPercent
        self.peakDrainRatePctPerHour = peakDrainRatePctPerHour
        self.avgThermalState = avgThermalState
        self.triggerRaw = trigger.rawValue
        self.peakSystemEnergyWatts = peakSystemEnergyWatts
        self.topSuspectsJSON = topSuspectsJSON
    }

    public var drainPercent: Double { startPercent - endPercent }
    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }
}
