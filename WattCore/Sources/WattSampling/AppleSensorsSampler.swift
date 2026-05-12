import Foundation
import WattSamplingC

public actor AppleSensorsSampler {
    public init() {}

    public func read() -> SensorsReading {
        let temps = readTemperatures()
        let fans = readFans()
        return SensorsReading(fanRPM: fans, temperatures: temps)
    }

    private func readTemperatures() -> [String: Double] {
        let capacity = 64
        var buffer = Array(repeating: watt_temp_reading_t(), count: capacity)
        let written = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
            Int(watt_read_temperatures(ptr.baseAddress, Int32(capacity)))
        }
        guard written > 0 else { return [:] }
        var dict: [String: Double] = [:]
        for i in 0..<written {
            let reading = buffer[i]
            let name = withUnsafeBytes(of: reading.name) { raw -> String in
                let bytes = raw.bindMemory(to: CChar.self)
                guard let baseAddress = bytes.baseAddress else { return "" }
                return String(cString: baseAddress)
            }
            if !name.isEmpty {
                dict[name] = reading.valueCelsius
            }
        }
        return dict
    }

    private func readFans() -> [Double] {
        let capacity = 16
        var buffer = Array(repeating: watt_fan_reading_t(), count: capacity)
        let written = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
            Int(watt_read_fans(ptr.baseAddress, Int32(capacity)))
        }
        guard written > 0 else { return [] }
        var rpms: [Double] = []
        for i in 0..<written {
            rpms.append(buffer[i].rpm)
        }
        return rpms
    }
}
