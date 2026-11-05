import Foundation
import IOKit

struct PowerReading: Codable {
    var volts: Double
    var amps: Double
    var externalPower: Bool
    var sampledAt: Date
    // Signed electrical battery flow. This is not CPU/SoC or AC wall power.
    var watts: Double { volts * amps }
    var hasUsableCurrent: Bool { externalPower || amps < -0.0001 }
    var sourceDescription: String {
        let source = externalPower ? "External power connected" : "On battery"
        guard hasUsableCurrent else { return source + " · current reading unavailable" }
        return source + String(format:" · %.2f V · %.3f A",volts,amps)
    }
    var label: String {
        guard hasUsableCurrent else { return "Battery power" }
        return watts < -0.05 ? "Battery discharge · estimate" : watts > 0.05 ? "Battery charging · estimate" : "Battery flow · estimate"
    }
    var formatted: String { hasUsableCurrent ? String(format: "%.1f W", abs(watts)) : "Unavailable" }
    static func decode(_ values:[String:Any],at date:Date=Date()) -> PowerReading? {
        guard let voltage=values["Voltage"] as? NSNumber,let external=values["ExternalConnected"] as? Bool else {return nil}
        let candidates=["InstantAmperage","Amperage"].compactMap {values[$0] as? NSNumber}.map {Double($0.int64Value)}.filter {abs($0)<100_000}
        guard let current=(external ? candidates.first : candidates.first(where:{$0 < 0}) ?? candidates.first),voltage.doubleValue>0,voltage.doubleValue<100_000 else {return nil}
        return PowerReading(volts:voltage.doubleValue/1000,amps:current/1000,externalPower:external,sampledAt:date)
    }
    static func read() -> PowerReading? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let values = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        return decode(values)
    }
}
