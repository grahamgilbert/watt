import Foundation

/// Streaming detector for sustained battery-drain episodes.
///
/// `EpisodeDetector` is a value type — `feed(_:)` is mutating and returns any
/// state transitions caused by the new sample. It keeps a fixed-size rolling
/// window in memory; every method is pure and synchronous so the higher-level
/// `SamplingCoordinator` actor can drive it without crossing isolation domains.
public struct EpisodeDetector: Sendable {
    public struct Configuration: Sendable {
        /// Minimum sustained drain rate (percent per hour) to start an
        /// episode. Default is 12 %/h.
        public var startThresholdPctPerHour: Double
        /// Episode ends when drain drops below `startThresholdPctPerHour /
        /// endThresholdDivisor`. Default 2.0.
        public var endThresholdDivisor: Double
        /// Number of consecutive samples that must clear the start/end
        /// threshold. Default 3.
        public var stickyCount: Int
        /// Window size (samples). Default 20 (≈10 min at 30 s cadence).
        public var windowSize: Int
        /// Maximum gap between samples that still counts as continuous; gaps
        /// larger than this end an open episode (sleep/wake).
        public var maxSampleGap: TimeInterval

        public init(
            startThresholdPctPerHour: Double = 12,
            endThresholdDivisor: Double = 2,
            stickyCount: Int = 3,
            windowSize: Int = 20,
            maxSampleGap: TimeInterval = 60
        ) {
            self.startThresholdPctPerHour = startThresholdPctPerHour
            self.endThresholdDivisor = endThresholdDivisor
            self.stickyCount = stickyCount
            self.windowSize = windowSize
            self.maxSampleGap = maxSampleGap
        }
    }

    public enum Event: Sendable, Equatable {
        case started(at: Date, percent: Double)
        case ended(at: Date, percent: Double, peakDrainRatePctPerHour: Double, avgThermalState: Int)
        case noChange
    }

    public private(set) var configuration: Configuration
    public private(set) var inEpisode: Bool = false
    public private(set) var episodeStart: Date?
    public private(set) var episodeStartPercent: Double?
    public private(set) var peakDrainRate: Double = 0
    public private(set) var thermalAccumulator: Int = 0
    public private(set) var thermalSampleCount: Int = 0

    private var window: [SamplePoint] = []
    private var aboveStartCount = 0
    private var belowEndCount = 0

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        self.window.reserveCapacity(configuration.windowSize + 1)
    }

    @discardableResult
    public mutating func feed(_ point: SamplePoint) -> Event {
        let priorLast = window.last
        if let prior = priorLast,
           point.timestamp.timeIntervalSince(prior.timestamp) > configuration.maxSampleGap,
           inEpisode {
            return endEpisode(reason: .gap, atTimestamp: prior.timestamp, atPercent: prior.batteryPercent)
        }

        appendToWindow(point)

        if point.isCharging, inEpisode {
            return endEpisode(reason: .plugIn, atTimestamp: point.timestamp, atPercent: point.batteryPercent)
        }

        let drainRate = currentDrainRatePctPerHour()
        if inEpisode {
            peakDrainRate = max(peakDrainRate, drainRate)
            thermalAccumulator += point.thermalState
            thermalSampleCount += 1
        }

        let endThreshold = configuration.startThresholdPctPerHour / max(configuration.endThresholdDivisor, .leastNormalMagnitude)

        if !inEpisode {
            if !point.isCharging, drainRate >= configuration.startThresholdPctPerHour {
                aboveStartCount += 1
                if aboveStartCount >= configuration.stickyCount {
                    return startEpisode(at: point)
                }
            } else {
                aboveStartCount = 0
            }
            return .noChange
        } else {
            if drainRate < endThreshold {
                belowEndCount += 1
                if belowEndCount >= configuration.stickyCount {
                    return endEpisode(reason: .calmed, atTimestamp: point.timestamp, atPercent: point.batteryPercent)
                }
            } else {
                belowEndCount = 0
            }
            return .noChange
        }
    }

    private mutating func appendToWindow(_ point: SamplePoint) {
        window.append(point)
        if window.count > configuration.windowSize {
            window.removeFirst(window.count - configuration.windowSize)
        }
    }

    /// Least-squares slope of `batteryPercent` over the current window,
    /// converted to percent-per-hour. Negative values mean the battery is
    /// falling; we return the magnitude so callers can compare against
    /// thresholds without sign confusion.
    public func currentDrainRatePctPerHour() -> Double {
        guard window.count >= 2 else { return 0 }
        let firstTime = window[0].timestamp.timeIntervalSinceReferenceDate
        let xs = window.map { $0.timestamp.timeIntervalSinceReferenceDate - firstTime }
        let ys = window.map(\.batteryPercent)
        let n = Double(window.count)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).map(*).reduce(0, +)
        let sumXX = xs.map { $0 * $0 }.reduce(0, +)
        let denominator = n * sumXX - sumX * sumX
        guard abs(denominator) > .leastNormalMagnitude else { return 0 }
        let slopePctPerSecond = (n * sumXY - sumX * sumY) / denominator
        // slope is negative on drain; report magnitude in %/hour.
        return -slopePctPerSecond * 3600
    }

    private enum EndReason { case calmed, plugIn, gap }

    private mutating func startEpisode(at point: SamplePoint) -> Event {
        let startSample = window.first ?? point
        inEpisode = true
        episodeStart = startSample.timestamp
        episodeStartPercent = startSample.batteryPercent
        peakDrainRate = currentDrainRatePctPerHour()
        thermalAccumulator = point.thermalState
        thermalSampleCount = 1
        belowEndCount = 0
        aboveStartCount = 0
        return .started(at: startSample.timestamp, percent: startSample.batteryPercent)
    }

    private mutating func endEpisode(reason: EndReason, atTimestamp: Date, atPercent: Double) -> Event {
        let avgThermal = thermalSampleCount > 0
            ? Int((Double(thermalAccumulator) / Double(thermalSampleCount)).rounded())
            : 0
        let event = Event.ended(
            at: atTimestamp,
            percent: atPercent,
            peakDrainRatePctPerHour: peakDrainRate,
            avgThermalState: avgThermal
        )
        inEpisode = false
        episodeStart = nil
        episodeStartPercent = nil
        peakDrainRate = 0
        thermalAccumulator = 0
        thermalSampleCount = 0
        belowEndCount = 0
        aboveStartCount = 0
        _ = reason
        return event
    }
}
