import Foundation
import SwiftData

@Model
public final class DrainEpisode {
    @Attribute(.unique) public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    public var startPercent: Double
    public var endPercent: Double
    public var peakDrainRatePctPerHour: Double
    public var avgThermalState: Int
    public var topSuspectsJSON: Data
    @Relationship(deleteRule: .nullify, inverse: \Report.episode)
    public var reports: [Report] = []

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        endedAt: Date? = nil,
        startPercent: Double,
        endPercent: Double,
        peakDrainRatePctPerHour: Double,
        avgThermalState: Int,
        topSuspectsJSON: Data = Data()
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.startPercent = startPercent
        self.endPercent = endPercent
        self.peakDrainRatePctPerHour = peakDrainRatePctPerHour
        self.avgThermalState = avgThermalState
        self.topSuspectsJSON = topSuspectsJSON
    }

    public var drainPercent: Double { startPercent - endPercent }
    public var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }
}
