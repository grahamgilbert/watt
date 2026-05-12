import Foundation
@testable import WattAnalysis
@testable import WattModels

enum Fixtures {
    static let referenceDate = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Generates a series of `SamplePoint`s for testing. Each step is 30 s.
    /// The closure is called per-sample with index and time offset; return the
    /// configured point.
    static func samples(
        count: Int,
        step: TimeInterval = 30,
        start: Date = referenceDate,
        configure: (Int, Date) -> SamplePoint
    ) -> [SamplePoint] {
        (0..<count).map { i in
            let t = start.addingTimeInterval(TimeInterval(i) * step)
            return configure(i, t)
        }
    }

    /// Steady drain: battery falls linearly at the requested %/h while
    /// unplugged. Useful baseline for the EpisodeDetector.
    static func steadyDrain(
        startPercent: Double,
        ratePctPerHour: Double,
        count: Int,
        step: TimeInterval = 30,
        start: Date = referenceDate,
        thermalState: Int = 0,
        cpu: Double = 0.2,
        memory: Double = 40
    ) -> [SamplePoint] {
        samples(count: count, step: step, start: start) { i, t in
            let elapsed = TimeInterval(i) * step
            let pct = startPercent - ratePctPerHour * elapsed / 3600
            return SamplePoint(
                timestamp: t,
                batteryPercent: pct,
                isCharging: false,
                instantaneousWatts: 18,
                systemCPUUsage: cpu,
                memoryPressurePct: memory,
                memoryUsedBytes: 16_000_000_000,
                thermalState: thermalState
            )
        }
    }

    /// Two-process archetype: writer process produces deltas of `writeBytes`
    /// per sample; reader produces `readBytes`.
    static func writerReaderProcesses(
        writerPid: Int32 = 81134,
        writerName: String = "claude",
        readerPid: Int32 = 412,
        readerName: String = "falconctl",
        writeBytes: UInt64,
        readBytes: UInt64,
        cpuPerSample: Double = 1.5,
        energyPerSample: UInt64 = 800_000_000
    ) -> [ProcessPoint] {
        [
            ProcessPoint(
                pid: writerPid, name: writerName, bundleID: "com.anthropic.claude",
                cpuTimeDelta: cpuPerSample,
                energyNanojoulesDelta: energyPerSample,
                billedEnergyDelta: energyPerSample,
                diskReadBytesDelta: 0,
                diskWriteBytesDelta: writeBytes,
                pageinsDelta: 200,
                residentBytes: 600_000_000
            ),
            ProcessPoint(
                pid: readerPid, name: readerName, bundleID: "com.crowdstrike.falcon",
                cpuTimeDelta: cpuPerSample * 0.8,
                energyNanojoulesDelta: UInt64(Double(energyPerSample) * 0.7),
                billedEnergyDelta: UInt64(Double(energyPerSample) * 0.7),
                diskReadBytesDelta: readBytes,
                diskWriteBytesDelta: 0,
                pageinsDelta: 50,
                residentBytes: 250_000_000
            ),
            // A benign process that is alive throughout.
            ProcessPoint(
                pid: 198, name: "WindowServer", bundleID: nil,
                cpuTimeDelta: 0.05,
                energyNanojoulesDelta: 50_000_000,
                billedEnergyDelta: 50_000_000,
                diskReadBytesDelta: 0,
                diskWriteBytesDelta: 0,
                pageinsDelta: 1,
                residentBytes: 80_000_000
            )
        ]
    }
}
