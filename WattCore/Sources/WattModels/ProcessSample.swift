import Foundation
import SwiftData

@Model
public final class ProcessSample {
    public var pid: Int32
    public var name: String
    public var bundleID: String?
    public var executablePath: String?
    public var cpuTimeDelta: Double
    public var energyNanojoulesDelta: UInt64
    public var billedEnergyDelta: UInt64
    public var billedSystemTimeDelta: UInt64
    public var diskReadBytesDelta: UInt64
    public var diskWriteBytesDelta: UInt64
    public var pageinsDelta: UInt64
    public var residentBytes: UInt64
    public var sample: Sample?

    public init(
        pid: Int32,
        name: String,
        bundleID: String? = nil,
        executablePath: String? = nil,
        cpuTimeDelta: Double,
        energyNanojoulesDelta: UInt64,
        billedEnergyDelta: UInt64,
        billedSystemTimeDelta: UInt64,
        diskReadBytesDelta: UInt64,
        diskWriteBytesDelta: UInt64,
        pageinsDelta: UInt64,
        residentBytes: UInt64,
        sample: Sample? = nil
    ) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.executablePath = executablePath
        self.cpuTimeDelta = cpuTimeDelta
        self.energyNanojoulesDelta = energyNanojoulesDelta
        self.billedEnergyDelta = billedEnergyDelta
        self.billedSystemTimeDelta = billedSystemTimeDelta
        self.diskReadBytesDelta = diskReadBytesDelta
        self.diskWriteBytesDelta = diskWriteBytesDelta
        self.pageinsDelta = pageinsDelta
        self.residentBytes = residentBytes
        self.sample = sample
    }
}
