import Foundation

public struct TimelineEntry: Sendable, Hashable, Codable {
    public enum Kind: String, Sendable, Hashable, Codable {
        case userAction
        case systemTransition
        case processOnset
        case samplePeak
        case samplePoint
    }

    public var timestamp: Date
    public var kind: Kind
    public var oneLine: String

    public init(timestamp: Date, kind: Kind, oneLine: String) {
        self.timestamp = timestamp
        self.kind = kind
        self.oneLine = oneLine
    }
}

public enum TimelineBuilder {
    public struct Configuration: Sendable {
        public var maxEntries: Int
        public var samplePointEvery: TimeInterval
        public var processOnsetThreshold: Double  // fraction of episode peak

        public init(
            maxEntries: Int = 50,
            samplePointEvery: TimeInterval = 90,
            processOnsetThreshold: Double = 0.05
        ) {
            self.maxEntries = maxEntries
            self.samplePointEvery = samplePointEvery
            self.processOnsetThreshold = processOnsetThreshold
        }
    }

    public static func build(
        samples: [SamplePoint],
        events: [UserEventPoint],
        suspects: [Suspect],
        configuration: Configuration = .init()
    ) -> [TimelineEntry] {
        guard let firstSample = samples.min(by: { $0.timestamp < $1.timestamp }),
              let lastSample = samples.max(by: { $0.timestamp < $1.timestamp })
        else { return [] }
        let sortedSamples = samples.sorted { $0.timestamp < $1.timestamp }
        let start = firstSample.timestamp
        let end = lastSample.timestamp

        var entries: [TimelineEntry] = []

        for event in events where event.timestamp >= start && event.timestamp <= end {
            entries.append(makeUserActionEntry(for: event, samples: sortedSamples))
        }

        for entry in derivedSystemTransitions(samples: sortedSamples)
        where !entries.contains(where: { $0.timestamp == entry.timestamp && $0.kind == .userAction }) {
            entries.append(entry)
        }

        for entry in derivedProcessOnsets(
            samples: sortedSamples,
            suspects: suspects,
            threshold: configuration.processOnsetThreshold
        ) {
            entries.append(entry)
        }

        for entry in derivedPeaks(samples: sortedSamples) {
            entries.append(entry)
        }

        for entry in derivedSamplePoints(
            samples: sortedSamples,
            cadence: configuration.samplePointEvery,
            keepingTimestamps: Set(entries.map(\.timestamp))
        ) {
            entries.append(entry)
        }

        entries.sort { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return priority(lhs.kind) < priority(rhs.kind)
        }

        // Cap at maxEntries by dropping the lowest-priority extras.
        if entries.count > configuration.maxEntries {
            let priorities = entries.enumerated().sorted { lhs, rhs in
                let lp = priority(lhs.element.kind)
                let rp = priority(rhs.element.kind)
                if lp != rp { return lp < rp }
                return lhs.offset < rhs.offset
            }
            let keptIndices = Set(priorities.prefix(configuration.maxEntries).map(\.offset))
            entries = entries.enumerated().filter { keptIndices.contains($0.offset) }.map(\.element)
        }

        return entries
    }

    // MARK: - User actions

    private static func makeUserActionEntry(
        for event: UserEventPoint,
        samples: [SamplePoint]
    ) -> TimelineEntry {
        let battery = batteryAt(timestamp: event.timestamp, samples: samples)
        let line = userActionLine(for: event, battery: battery)
        return TimelineEntry(timestamp: event.timestamp, kind: .userAction, oneLine: line)
    }

    private static func userActionLine(for event: UserEventPoint, battery: Double?) -> String {
        let appName = event.appName ?? "an app"
        let aside = batteryAside(battery)
        switch event.kind {
        case .appActivated:    return "User activated **\(appName)**\(aside)."
        case .appLaunched:     return "User launched **\(appName)**\(aside)."
        case .appTerminated:   return "**\(appName)** quit\(aside)."
        case .powerPlugged:    return "Plugged in charger\(aside)."
        case .powerUnplugged:  return "Unplugged charger\(aside)."
        case .displaySleep:    return "Display went to sleep."
        case .displayWake:     return "Display woke."
        case .systemSleep:     return "System went to sleep."
        case .systemWake:      return "System woke."
        case .lockScreen:      return "User locked the screen."
        case .unlockScreen:    return "User unlocked the screen."
        case .thermalChanged:  return "Thermal state changed: \(event.detail ?? "unknown")."
        case .userNote:        return "Note: \(event.detail ?? "")"
        }
    }

    private static func batteryAside(_ battery: Double?) -> String {
        guard let battery, battery.isFinite else { return "" }
        return ". Battery \(Int(battery.rounded()))%"
    }

    private static func batteryAt(timestamp: Date, samples: [SamplePoint]) -> Double? {
        guard let nearest = samples.min(by: {
            abs($0.timestamp.timeIntervalSince(timestamp)) < abs($1.timestamp.timeIntervalSince(timestamp))
        }) else { return nil }
        return nearest.batteryPercent
    }

    // MARK: - System transitions derived from samples

    private static func derivedSystemTransitions(samples: [SamplePoint]) -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        let labels = ["nominal", "fair", "serious", "critical"]
        for i in 1..<samples.count {
            let prev = samples[i - 1]
            let cur = samples[i]
            if prev.thermalState != cur.thermalState {
                let from = labels[max(0, min(prev.thermalState, 3))]
                let to = labels[max(0, min(cur.thermalState, 3))]
                entries.append(TimelineEntry(
                    timestamp: cur.timestamp,
                    kind: .systemTransition,
                    oneLine: "Thermal state **\(from) → \(to)**."
                ))
            }
            if prev.isCharging != cur.isCharging {
                let line = cur.isCharging
                    ? "System reports charging started."
                    : "System reports running on battery."
                entries.append(TimelineEntry(
                    timestamp: cur.timestamp,
                    kind: .systemTransition,
                    oneLine: line
                ))
            }
        }
        return entries
    }

    // MARK: - Process onsets

    private static func derivedProcessOnsets(
        samples: [SamplePoint],
        suspects: [Suspect],
        threshold: Double
    ) -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        for suspect in suspects {
            let metric: (ProcessPoint) -> Double = { proc in
                Double(proc.energyNanojoulesDelta) +
                Double(proc.diskReadBytesDelta &+ proc.diskWriteBytesDelta) / 1024
            }
            let series: [(Date, Double)] = samples.compactMap { sample in
                if let proc = sample.processes.first(where: { $0.pid == suspect.pid }) {
                    return (sample.timestamp, metric(proc))
                }
                return nil
            }
            guard let peak = series.map(\.1).max(), peak > 0 else { continue }
            let firstAbove = series.first { $0.1 >= peak * threshold && $0.1 > 0 }
            if let firstAbove {
                entries.append(TimelineEntry(
                    timestamp: firstAbove.0,
                    kind: .processOnset,
                    oneLine: "`\(suspect.name)` (pid \(suspect.pid)) became active."
                ))
            }
        }
        return entries
    }

    // MARK: - Metric peaks

    private static func derivedPeaks(samples: [SamplePoint]) -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        if let peakFan = samples.max(by: { $0.maxFanRPM < $1.maxFanRPM }), peakFan.maxFanRPM > 0 {
            entries.append(TimelineEntry(
                timestamp: peakFan.timestamp,
                kind: .samplePeak,
                oneLine: "Fan reached **\(Int(peakFan.maxFanRPM.rounded())) RPM** (peak)."
            ))
        }
        if let hottest = samples.compactMap({ sample -> (Date, String, Double)? in
            guard let h = sample.hottestSensor else { return nil }
            return (sample.timestamp, h.key, h.value)
        }).max(by: { $0.2 < $1.2 }), hottest.2 > 0 {
            let value = String(format: "%.1f", hottest.2)
            entries.append(TimelineEntry(
                timestamp: hottest.0,
                kind: .samplePeak,
                oneLine: "Hottest sensor `\(hottest.1)` peaked at **\(value) °C**."
            ))
        }
        if let cpuPeak = samples.max(by: { $0.systemCPUUsage < $1.systemCPUUsage }), cpuPeak.systemCPUUsage > 0 {
            let pct = Int((cpuPeak.systemCPUUsage * 100).rounded())
            entries.append(TimelineEntry(
                timestamp: cpuPeak.timestamp,
                kind: .samplePeak,
                oneLine: "System CPU usage peaked at **\(pct)%**."
            ))
        }
        return entries
    }

    // MARK: - Sample points

    private static func derivedSamplePoints(
        samples: [SamplePoint],
        cadence: TimeInterval,
        keepingTimestamps: Set<Date>
    ) -> [TimelineEntry] {
        guard cadence > 0, let firstSample = samples.first else { return [] }
        var entries: [TimelineEntry] = []
        var nextEmit = firstSample.timestamp
        for sample in samples {
            if sample.timestamp < nextEmit { continue }
            if keepingTimestamps.contains(sample.timestamp) {
                nextEmit = sample.timestamp.addingTimeInterval(cadence)
                continue
            }
            entries.append(TimelineEntry(
                timestamp: sample.timestamp,
                kind: .samplePoint,
                oneLine: oneLineSample(sample)
            ))
            nextEmit = sample.timestamp.addingTimeInterval(cadence)
        }
        return entries
    }

    private static func oneLineSample(_ sample: SamplePoint) -> String {
        let pct = Int(sample.batteryPercent.rounded())
        let cpu = Int((sample.systemCPUUsage * 100).rounded())
        let fan = Int(sample.maxFanRPM.rounded())
        let temp = sample.hottestSensor?.value ?? 0
        return "Battery \(pct)%, CPU \(cpu)%, fan \(fan) RPM, hottest \(String(format: "%.1f", temp)) °C."
    }

    // MARK: - Priority

    private static func priority(_ kind: TimelineEntry.Kind) -> Int {
        switch kind {
        case .userAction:        return 0
        case .systemTransition:  return 1
        case .processOnset:      return 2
        case .samplePeak:        return 3
        case .samplePoint:       return 4
        }
    }
}
