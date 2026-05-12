import Foundation

public actor ThermalSampler {
    public init() {}

    public func read() -> ThermalReading {
        let state = ProcessInfo.processInfo.thermalState
        switch state {
        case .nominal:  return ThermalReading(rawValue: 0)
        case .fair:     return ThermalReading(rawValue: 1)
        case .serious:  return ThermalReading(rawValue: 2)
        case .critical: return ThermalReading(rawValue: 3)
        @unknown default: return ThermalReading(rawValue: 0)
        }
    }
}
