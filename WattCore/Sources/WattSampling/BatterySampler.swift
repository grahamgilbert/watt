import Foundation
import IOKit
import IOKit.ps

public actor BatterySampler {
    public init() {}

    public func read() -> BatteryReading {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return BatteryReading(batteryPercent: .nan, isCharging: false, instantaneousWatts: 0)
        }

        var bestPercent: Double = .nan
        var bestCharging = false
        var bestWatts: Double = 0

        for source in list {
            guard let dict = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: AnyObject] else {
                continue
            }
            // Only batteries — ignore UPS/AC.
            if (dict[kIOPSTypeKey] as? String) != kIOPSInternalBatteryType { continue }
            let current = (dict[kIOPSCurrentCapacityKey] as? Int) ?? 0
            let max = (dict[kIOPSMaxCapacityKey] as? Int) ?? 100
            // kIOPSPowerSourceStateKey is "AC Power" whenever the cable is
            // connected, even when the battery is full and kIOPSIsChargingKey
            // is false (conservation / optimised charging). This is the right
            // signal for the episode detector's AC vs battery path.
            let powerState = dict[kIOPSPowerSourceStateKey] as? String
            let isOnAC = (powerState == kIOPSACPowerValue)
            let amperage = (dict[kIOPSCurrentKey] as? Int) ?? 0     // mA, signed
            let voltage = (dict[kIOPSVoltageKey] as? Int) ?? 0       // mV
            let watts = abs(Double(amperage) * Double(voltage)) / 1_000_000.0

            bestPercent = (max > 0) ? Double(current) / Double(max) * 100 : .nan
            bestCharging = isOnAC
            bestWatts = watts
            break
        }
        return BatteryReading(
            batteryPercent: bestPercent,
            isCharging: bestCharging,
            instantaneousWatts: bestWatts
        )
    }
}
