import Foundation
import SwiftData
import WattAnalysis
import WattModels

/// Owns the SwiftData ModelContext for sampling writes. Confines all
/// inserts/saves to a single context so SwiftData's strict-concurrency rules
/// hold without any locks.
@ModelActor
public actor SamplingWriter {
    public func writeSample(point: SamplePoint) throws {
        let sample = Sample(
            timestamp: point.timestamp,
            batteryPercent: point.batteryPercent,
            isCharging: point.isCharging,
            instantaneousWatts: point.instantaneousWatts,
            systemEnergyWatts: point.systemEnergyWatts,
            systemCPUUsage: point.systemCPUUsage,
            memoryPressurePct: point.memoryPressurePct,
            memoryUsedBytes: point.memoryUsedBytes,
            thermalState: point.thermalState,
            fanRPM: point.fanRPM,
            temperatures: point.temperatures,
            fsEventsRate: point.fsEventsRate
        )
        modelContext.insert(sample)
        for proc in point.processes {
            let row = ProcessSample(
                pid: proc.pid,
                name: proc.name,
                bundleID: proc.bundleID,
                cpuTimeDelta: proc.cpuTimeDelta,
                energyNanojoulesDelta: proc.energyNanojoulesDelta,
                billedEnergyDelta: proc.billedEnergyDelta,
                billedSystemTimeDelta: 0,
                diskReadBytesDelta: proc.diskReadBytesDelta,
                diskWriteBytesDelta: proc.diskWriteBytesDelta,
                pageinsDelta: proc.pageinsDelta,
                residentBytes: proc.residentBytes,
                sample: sample
            )
            modelContext.insert(row)
        }
        try modelContext.save()
    }

    public func writeUserEvent(_ event: UserEventPoint) throws {
        let row = UserEvent(
            timestamp: event.timestamp,
            kind: event.kind,
            bundleID: event.bundleID,
            appName: event.appName,
            detail: event.detail
        )
        modelContext.insert(row)
        try modelContext.save()
    }

    public func writeEpisode(
        start: Date,
        startPercent: Double,
        trigger: DrainEpisodeTrigger = .batteryDrain
    ) throws -> PersistentIdentifier {
        let episode = DrainEpisode(
            startedAt: start,
            startPercent: startPercent,
            endPercent: startPercent,
            peakDrainRatePctPerHour: 0,
            avgThermalState: 0,
            trigger: trigger
        )
        modelContext.insert(episode)
        try modelContext.save()
        return episode.persistentModelID
    }

    public func updateEpisode(
        id: PersistentIdentifier,
        endedAt: Date,
        endPercent: Double,
        peakDrainRate: Double,
        peakSystemEnergyWatts: Double = 0,
        avgThermalState: Int
    ) throws {
        guard let episode = modelContext.model(for: id) as? DrainEpisode else { return }
        episode.endedAt = endedAt
        episode.endPercent = endPercent
        episode.peakDrainRatePctPerHour = peakDrainRate
        episode.peakSystemEnergyWatts = peakSystemEnergyWatts
        episode.avgThermalState = avgThermalState
        try modelContext.save()
    }

    public func writeReport(_ report: Report, attachingTo episodeID: PersistentIdentifier?) throws {
        if let episodeID, let episode = modelContext.model(for: episodeID) as? DrainEpisode {
            report.episode = episode
        }
        modelContext.insert(report)
        try modelContext.save()
    }

    public func pruneSamplesOlderThan(_ cutoff: Date) throws {
        let predicate = #Predicate<Sample> { $0.timestamp < cutoff }
        try modelContext.delete(model: Sample.self, where: predicate)
        try modelContext.save()
    }

    public struct EpisodeBounds: Sendable {
        public var startedAt: Date
        public var endedAt: Date
        public var startPercent: Double
        public var endPercent: Double
        public var peakDrainRatePctPerHour: Double
        public var peakSystemEnergyWatts: Double
        public var avgThermalState: Int
        public var trigger: DrainEpisodeTrigger
    }

    public func episodeBounds(id: PersistentIdentifier) throws -> EpisodeBounds? {
        guard let episode = modelContext.model(for: id) as? DrainEpisode else { return nil }
        return EpisodeBounds(
            startedAt: episode.startedAt,
            endedAt: episode.endedAt ?? Date(),
            startPercent: episode.startPercent,
            endPercent: episode.endPercent,
            peakDrainRatePctPerHour: episode.peakDrainRatePctPerHour,
            peakSystemEnergyWatts: episode.peakSystemEnergyWatts,
            avgThermalState: episode.avgThermalState,
            trigger: episode.trigger
        )
    }

    public func loadSamplePoints(in interval: ClosedRange<Date>) throws -> [SamplePoint] {
        let lower = interval.lowerBound
        let upper = interval.upperBound
        var descriptor = FetchDescriptor<Sample>(
            predicate: #Predicate<Sample> { $0.timestamp >= lower && $0.timestamp <= upper },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        descriptor.relationshipKeyPathsForPrefetching = [\Sample.processes]
        let samples = try modelContext.fetch(descriptor)
        return samples.map(SamplePoint.from)
    }

    public func loadUserEventPoints(in interval: ClosedRange<Date>) throws -> [UserEventPoint] {
        let lower = interval.lowerBound
        let upper = interval.upperBound
        let descriptor = FetchDescriptor<UserEvent>(
            predicate: #Predicate<UserEvent> { $0.timestamp >= lower && $0.timestamp <= upper },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        let events = try modelContext.fetch(descriptor)
        return events.map(UserEventPoint.from)
    }
}
