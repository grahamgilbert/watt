import Foundation

public let WattHelperMachServiceName = "com.grahamgilbert.watt.helper"

@objc public protocol WattHelperXPC {
    func samplePower(durationMillis: Int, reply: @escaping (Data?, Error?) -> Void)
    func ping(reply: @escaping (String) -> Void)
}
