import Foundation
import WattModels

/// Streaming detector for sustained drain / high-energy episodes.
///
/// `EpisodeDetector` does NOT trigger on momentary spikes. It maintains a
/// rolling window of samples and integrates real wall-clock energy across that
/// window. An episode starts only when the *aggregated* signal — total
/// percent dropped over the window for battery, or mean joules-per-second
/// over the window for AC — sits above its threshold for several samples in
/// a row, AND the window holds at least `minimumWindowSeconds` of data.
///
/// This is what catches the canonical "security agent spikes the CPU 60 W
/// for 1 s every 5 s while idling at 8 W between": each sample is below the
/// crude threshold, but the windowed integral lands well above.
public struct EpisodeDetector: Sendable {
    public struct Configuration: Sendable {
        /// Battery: minimum aggregated drop (percent of full battery) over
        /// the window required to trigger. 5 % over 10 minutes ≈ 30 %/h —
        /// far above idle on a typical M-series laptop, well below a runaway.
        public var batteryDrainThresholdPctOverWindow: Double
        /// AC: minimum mean value of `systemEnergyWatts` across the window
        /// required to trigger. `systemEnergyWatts` comes from IOReport
        /// (real watts from the kernel's energy counters). On Apple Silicon
        /// idle is ~3-8 W; a sustained security agent workload sits at
        /// 20-50 W. Threshold 18 W fires on real load without false-
        /// triggering normal browsing/coding idle.
        public var acHighEnergyThresholdMeanWatts: Double
        /// End thresholds are computed as start / divisor.
        public var endThresholdDivisor: Double
        /// Number of consecutive *new* samples (after window saturation) that
        /// must agree on the start condition before an episode begins. Keeps
        /// us from triggering on a single tail-end blip.
        public var stickyCount: Int
        /// Window length in seconds. The detector requires at least this much
        /// real time of data before it will consider the start condition.
        /// 10 minutes at 30 s/sample = 20 samples — enough to integrate a
        /// periodic spiker while ignoring momentary bursts.
        public var windowSeconds: TimeInterval
        /// Maximum gap between samples that still counts as continuous; gaps
        /// larger than this end an open episode (sleep/wake) and reset the
        /// window so the saturation requirement starts over.
        public var maxSampleGap: TimeInterval

        public init(
            batteryDrainThresholdPctOverWindow: Double = 5,
            acHighEnergyThresholdMeanWatts: Double = 18,
            endThresholdDivisor: Double = 2,
            stickyCount: Int = 3,
            windowSeconds: TimeInterval = 600,
            maxSampleGap: TimeInterval = 60
        ) {
            self.batteryDrainThresholdPctOverWindow = batteryDrainThresholdPctOverWindow
            self.acHighEnergyThresholdMeanWatts = acHighEnergyThresholdMeanWatts
            self.endThresholdDivisor = endThresholdDivisor
            self.stickyCount = stickyCount
            self.windowSeconds = windowSeconds
            self.maxSampleGap = maxSampleGap
        }
    }

    public enum Event: Sendable, Equatable {
        case started(at: Date, percent: Double, trigger: DrainEpisodeTrigger)
        case ended(
            at: Date,
            percent: Double,
            peakDrainRatePctPerHour: Double,
            peakSystemEnergyWatts: Double,
            avgThermalState: Int,
            trigger: DrainEpisodeTrigger
        )
        case noChange
    }

    public private(set) var configuration: Configuration
    public private(set) var inEpisode: Bool = false
    public private(set) var episodeStart: Date?
    public private(set) var episodeStartPercent: Double?
    public private(set) var trigger: DrainEpisodeTrigger = .batteryDrain
    public private(set) var peakDrainRate: Double = 0
    public private(set) var peakSystemEnergyWatts: Double = 0
    public private(set) var thermalAccumulator: Int = 0
    public private(set) var thermalSampleCount: Int = 0

    private var window: [SamplePoint] = []
    private var aboveBatteryCount = 0
    private var aboveEnergyCount = 0
    private var belowEndCount = 0

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    @discardableResult
    public mutating func feed(_ point: SamplePoint) -> Event {
        let priorLast = window.last
        if let prior = priorLast,
           point.timestamp.timeIntervalSince(prior.timestamp) > configuration.maxSampleGap {
            // A long gap (sleep/wake) invalidates the window. End any open
            // episode and reset accumulators so the next start has to clear
            // saturation again.
            let gapEvent: Event
            if inEpisode {
                gapEvent = endEpisode(reason: .gap, at: prior.timestamp, percent: prior.batteryPercent)
            } else {
                gapEvent = .noChange
            }
            window.removeAll(keepingCapacity: true)
            aboveBatteryCount = 0
            aboveEnergyCount = 0
            belowEndCount = 0
            window.append(point)
            return gapEvent
        }

        appendToWindow(point)

        // Power-source transition can end an open episode early.
        if inEpisode {
            switch trigger {
            case .batteryDrain where point.isCharging:
                return endEpisode(reason: .plugIn, at: point.timestamp, percent: point.batteryPercent)
            case .acHighEnergy where !point.isCharging:
                return endEpisode(reason: .unplug, at: point.timestamp, percent: point.batteryPercent)
            default:
                break
            }
        }

        if inEpisode {
            peakDrainRate = max(peakDrainRate, currentDrainRatePctPerHour())
            peakSystemEnergyWatts = max(peakSystemEnergyWatts, point.systemEnergyWatts)
            thermalAccumulator += point.thermalState
            thermalSampleCount += 1
        }

        // The detector needs a saturated window before it can talk about
        // sustained behaviour. While the window is still warming up, just
        // accumulate.
        if !windowIsSaturated() {
            return .noChange
        }

        if !inEpisode {
            return checkStartConditions(point: point)
        }
        return checkEndCondition(point: point)
    }

    private mutating func checkStartConditions(point: SamplePoint) -> Event {
        if !point.isCharging {
            aboveEnergyCount = 0
            let drop = windowDrainPctTotal()
            if drop >= configuration.batteryDrainThresholdPctOverWindow {
                aboveBatteryCount += 1
                if aboveBatteryCount >= configuration.stickyCount {
                    return startEpisode(at: point, trigger: .batteryDrain)
                }
            } else {
                aboveBatteryCount = 0
            }
            return .noChange
        }

        aboveBatteryCount = 0
        let mean = windowMeanWatts()
        if mean >= configuration.acHighEnergyThresholdMeanWatts {
            aboveEnergyCount += 1
            if aboveEnergyCount >= configuration.stickyCount {
                return startEpisode(at: point, trigger: .acHighEnergy)
            }
        } else {
            aboveEnergyCount = 0
        }
        return .noChange
    }

    private mutating func checkEndCondition(point: SamplePoint) -> Event {
        let calmed: Bool
        switch trigger {
        case .batteryDrain:
            let endThreshold = configuration.batteryDrainThresholdPctOverWindow
                / max(configuration.endThresholdDivisor, .leastNormalMagnitude)
            calmed = windowDrainPctTotal() < endThreshold
        case .acHighEnergy:
            let endThreshold = configuration.acHighEnergyThresholdMeanWatts
                / max(configuration.endThresholdDivisor, .leastNormalMagnitude)
            calmed = windowMeanWatts() < endThreshold
        case .userTriggered:
            // The live detector never owns a userTriggered episode; those are
            // synthesised by ReportCoordinator and never enter the streaming
            // pipeline. Treat as immediately calmed in the unlikely event.
            calmed = true
        }
        if calmed {
            belowEndCount += 1
            if belowEndCount >= configuration.stickyCount {
                return endEpisode(reason: .calmed, at: point.timestamp, percent: point.batteryPercent)
            }
        } else {
            belowEndCount = 0
        }
        return .noChange
    }

    private mutating func appendToWindow(_ point: SamplePoint) {
        window.append(point)
        // Drop samples whose age relative to the newest is *strictly greater
        // than* windowSeconds. Keeping samples whose age is exactly
        // windowSeconds (boundary case) ensures the window can grow to span
        // the full configured duration.
        let cutoff = point.timestamp.addingTimeInterval(-configuration.windowSeconds)
        while window.count > 2, let first = window.first, first.timestamp < cutoff {
            window.removeFirst()
        }
    }

    /// True once the buffered window spans (within sampling tolerance) the
    /// configured duration. Sampling cadence > 0 means consecutive samples
    /// are typically `cadence` apart, so the maximum span we ever observe
    /// is roughly `windowSeconds - cadence`. Allow a 90% tolerance so the
    /// detector starts evaluating without waiting for a perfect span.
    public func windowIsSaturated() -> Bool {
        guard let first = window.first, let last = window.last else { return false }
        let span = last.timestamp.timeIntervalSince(first.timestamp)
        return span >= configuration.windowSeconds * 0.9
    }

    /// Total battery drop in percent across the current window. Negative
    /// values are clamped to zero (the battery never goes up while
    /// discharging).
    public func windowDrainPctTotal() -> Double {
        guard let first = window.first, let last = window.last else { return 0 }
        return max(first.batteryPercent - last.batteryPercent, 0)
    }

    /// Time-weighted mean wattage across the window. Each sample's wattage
    /// applies for the interval it represents (current sample's timestamp
    /// minus prior sample's timestamp). This is robust against spiky
    /// workloads where many samples sit at idle and a few sit at peak.
    public func windowMeanWatts() -> Double {
        guard window.count >= 2 else { return 0 }
        var totalEnergyJoules = 0.0
        var totalSeconds = 0.0
        for i in 1..<window.count {
            let prev = window[i - 1]
            let cur = window[i]
            let dt = cur.timestamp.timeIntervalSince(prev.timestamp)
            guard dt > 0 else { continue }
            // Trapezoidal integration so single-sample spikes are scaled by
            // their actual elapsed window, not given full window weight.
            let avgWatts = (prev.systemEnergyWatts + cur.systemEnergyWatts) / 2
            totalEnergyJoules += avgWatts * dt
            totalSeconds += dt
        }
        guard totalSeconds > 0 else { return 0 }
        return totalEnergyJoules / totalSeconds
    }

    /// Convenience: the windowed-mean drop expressed as %/hour, used for
    /// reporting and the AI prompt. Computed from `windowDrainPctTotal()` over
    /// the window's wall-clock duration.
    public func currentDrainRatePctPerHour() -> Double {
        guard let first = window.first, let last = window.last else { return 0 }
        let dt = last.timestamp.timeIntervalSince(first.timestamp)
        guard dt > 0 else { return 0 }
        return windowDrainPctTotal() / dt * 3600
    }

    private enum EndReason { case calmed, plugIn, unplug, gap }

    private mutating func startEpisode(
        at point: SamplePoint,
        trigger: DrainEpisodeTrigger
    ) -> Event {
        let startSample = window.first ?? point
        inEpisode = true
        episodeStart = startSample.timestamp
        episodeStartPercent = startSample.batteryPercent
        self.trigger = trigger
        peakDrainRate = currentDrainRatePctPerHour()
        peakSystemEnergyWatts = window.map(\.systemEnergyWatts).max() ?? point.systemEnergyWatts
        thermalAccumulator = point.thermalState
        thermalSampleCount = 1
        belowEndCount = 0
        aboveBatteryCount = 0
        aboveEnergyCount = 0
        return .started(at: startSample.timestamp, percent: startSample.batteryPercent, trigger: trigger)
    }

    private mutating func endEpisode(
        reason: EndReason,
        at timestamp: Date,
        percent: Double
    ) -> Event {
        let avgThermal = thermalSampleCount > 0
            ? Int((Double(thermalAccumulator) / Double(thermalSampleCount)).rounded())
            : 0
        let event = Event.ended(
            at: timestamp,
            percent: percent,
            peakDrainRatePctPerHour: peakDrainRate,
            peakSystemEnergyWatts: peakSystemEnergyWatts,
            avgThermalState: avgThermal,
            trigger: trigger
        )
        inEpisode = false
        episodeStart = nil
        episodeStartPercent = nil
        peakDrainRate = 0
        peakSystemEnergyWatts = 0
        thermalAccumulator = 0
        thermalSampleCount = 0
        belowEndCount = 0
        aboveBatteryCount = 0
        aboveEnergyCount = 0
        _ = reason
        return event
    }
}
