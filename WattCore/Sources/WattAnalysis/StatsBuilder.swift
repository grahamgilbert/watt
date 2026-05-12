import Foundation

public struct EpisodeStats: Sendable, Hashable, Codable {
    public var startedAt: Date
    public var endedAt: Date
    public var durationSeconds: Double
    public var startPercent: Double
    public var endPercent: Double
    public var drainPercent: Double
    public var peakDrainRatePctPerHour: Double
    public var meanCPUUsage: Double
    public var peakCPUUsage: Double
    public var meanMemoryPressurePct: Double
    public var peakMemoryPressurePct: Double
    public var maxFanRPM: Double
    public var hottestSensorName: String?
    public var hottestSensorCelsius: Double?
    public var thermalRunRaw: [Int]
    public var thermalSummary: String
    public var fsEventsRatePeak: Double
    public var sampleCount: Int

    public var durationMinutes: Double { durationSeconds / 60 }

    public init(
        startedAt: Date,
        endedAt: Date,
        durationSeconds: Double,
        startPercent: Double,
        endPercent: Double,
        drainPercent: Double,
        peakDrainRatePctPerHour: Double,
        meanCPUUsage: Double,
        peakCPUUsage: Double,
        meanMemoryPressurePct: Double,
        peakMemoryPressurePct: Double,
        maxFanRPM: Double,
        hottestSensorName: String?,
        hottestSensorCelsius: Double?,
        thermalRunRaw: [Int],
        thermalSummary: String,
        fsEventsRatePeak: Double,
        sampleCount: Int
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.startPercent = startPercent
        self.endPercent = endPercent
        self.drainPercent = drainPercent
        self.peakDrainRatePctPerHour = peakDrainRatePctPerHour
        self.meanCPUUsage = meanCPUUsage
        self.peakCPUUsage = peakCPUUsage
        self.meanMemoryPressurePct = meanMemoryPressurePct
        self.peakMemoryPressurePct = peakMemoryPressurePct
        self.maxFanRPM = maxFanRPM
        self.hottestSensorName = hottestSensorName
        self.hottestSensorCelsius = hottestSensorCelsius
        self.thermalRunRaw = thermalRunRaw
        self.thermalSummary = thermalSummary
        self.fsEventsRatePeak = fsEventsRatePeak
        self.sampleCount = sampleCount
    }
}

public enum StatsBuilder {
    public static func build(samples: [SamplePoint]) -> EpisodeStats {
        precondition(!samples.isEmpty, "StatsBuilder requires at least one sample")
        let sorted = samples.sorted { $0.timestamp < $1.timestamp }
        guard let first = sorted.first, let last = sorted.last else {
            preconditionFailure("non-empty array yields nil first/last")
        }
        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        let drainPercent = max(first.batteryPercent - last.batteryPercent, 0)
        let peakRate = peakDrainRate(samples: sorted)
        let cpuValues = sorted.map(\.systemCPUUsage)
        let memValues = sorted.map(\.memoryPressurePct)
        let fanMax = sorted.map(\.maxFanRPM).max() ?? 0
        let hottest = sorted.compactMap(\.hottestSensor).max(by: { $0.value < $1.value })
        let thermalRaw = sorted.map(\.thermalState)
        let thermalSummary = summarizeThermal(thermalRaw)
        let fsPeak = sorted.map(\.fsEventsRate).max() ?? 0

        return EpisodeStats(
            startedAt: first.timestamp,
            endedAt: last.timestamp,
            durationSeconds: duration,
            startPercent: first.batteryPercent,
            endPercent: last.batteryPercent,
            drainPercent: drainPercent,
            peakDrainRatePctPerHour: peakRate,
            meanCPUUsage: mean(cpuValues),
            peakCPUUsage: cpuValues.max() ?? 0,
            meanMemoryPressurePct: mean(memValues),
            peakMemoryPressurePct: memValues.max() ?? 0,
            maxFanRPM: fanMax,
            hottestSensorName: hottest?.key,
            hottestSensorCelsius: hottest?.value,
            thermalRunRaw: thermalRaw,
            thermalSummary: thermalSummary,
            fsEventsRatePeak: fsPeak,
            sampleCount: sorted.count
        )
    }

    /// Sliding-window peak drain rate: take every contiguous trio and find the
    /// largest %-per-hour drop. Robust to the OS reporting battery in 1 %
    /// integer steps because we look at three consecutive points.
    private static func peakDrainRate(samples: [SamplePoint]) -> Double {
        guard samples.count >= 2 else { return 0 }
        var peak = 0.0
        for window in samples.windows(of: 3) where window.count >= 2 {
            guard let first = window.first, let last = window.last else { continue }
            let dt = last.timestamp.timeIntervalSince(first.timestamp)
            guard dt > 0 else { continue }
            let drop = first.batteryPercent - last.batteryPercent
            let perHour = drop / dt * 3600
            if perHour > peak { peak = perHour }
        }
        return peak
    }

    private static func summarizeThermal(_ raw: [Int]) -> String {
        let labels = ["nominal", "fair", "serious", "critical"]
        guard let first = raw.first, let last = raw.last else { return "n/a" }
        let highest = raw.max() ?? first
        if first == last && first == highest {
            return labels[clamp(first)]
        }
        return "\(labels[clamp(first)]) → peak \(labels[clamp(highest)]) → \(labels[clamp(last)])"
    }

    private static func clamp(_ x: Int) -> Int { min(max(x, 0), 3) }

    private static func mean(_ xs: [Double]) -> Double {
        xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count)
    }
}

extension Array {
    func windows(of size: Int) -> [ArraySlice<Element>] {
        guard size > 0, count >= size else {
            return count == 0 ? [] : [self.prefix(count)]
        }
        return (0...(count - size)).map { self[$0..<($0 + size)] }
    }
}
