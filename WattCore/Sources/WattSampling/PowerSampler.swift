import Foundation
import WattSamplingC

/// Reads system power (watts) from IOKit's `IOReport` framework. Same data
/// source Activity Monitor uses for its Energy column. Unlike the
/// `ri_energy_nj`-derived aggregate this replaces, IOReport returns the
/// kernel's actual energy counters per subsystem (CPU package, GPU, ANE,
/// DRAM). On Apple Silicon this matches wall power within a few hundred
/// milliwatts.
///
/// First call seeds the prior counter values and returns 0 watts. Subsequent
/// calls return the mean watts across the elapsed interval since the previous
/// call.
public actor PowerSampler {
    public struct Reading: Sendable {
        public var totalWatts: Double
        public var cpuWatts: Double
        public var gpuWatts: Double
        public var aneWatts: Double
        public var dramWatts: Double
        public var elapsedSeconds: Double
        public var available: Bool

        public static let unavailable = Reading(
            totalWatts: 0,
            cpuWatts: 0,
            gpuWatts: 0,
            aneWatts: 0,
            dramWatts: 0,
            elapsedSeconds: 0,
            available: false
        )
    }

    private var opened = false

    public init() {}

    public func read() -> Reading {
        if !opened {
            opened = (watt_ioreport_open() == 0)
            guard opened else { return .unavailable }
        }
        var raw = watt_power_sample_t()
        let result = watt_ioreport_sample(&raw)
        guard result == 0 else { return .unavailable }
        return Reading(
            totalWatts: raw.total_watts,
            cpuWatts: raw.cpu_watts,
            gpuWatts: raw.gpu_watts,
            aneWatts: raw.ane_watts,
            dramWatts: raw.dram_watts,
            elapsedSeconds: raw.elapsed_seconds,
            available: true
        )
    }

    public func close() {
        if opened {
            watt_ioreport_close()
            opened = false
        }
    }
}
