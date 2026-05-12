import Foundation

public struct Suspect: Sendable, Hashable, Codable {
    public var pid: Int32
    public var name: String
    public var bundleID: String?
    public var executablePath: String?
    public var totalCPUTime: Double
    public var totalEnergyNanojoules: UInt64
    public var totalDiskReadBytes: UInt64
    public var totalDiskWriteBytes: UInt64
    public var totalPageins: UInt64
    public var peakResidentBytes: UInt64
    public var samplesCovered: Int
    public var score: Double

    public init(
        pid: Int32,
        name: String,
        bundleID: String? = nil,
        executablePath: String? = nil,
        totalCPUTime: Double,
        totalEnergyNanojoules: UInt64,
        totalDiskReadBytes: UInt64,
        totalDiskWriteBytes: UInt64,
        totalPageins: UInt64,
        peakResidentBytes: UInt64,
        samplesCovered: Int,
        score: Double
    ) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.executablePath = executablePath
        self.totalCPUTime = totalCPUTime
        self.totalEnergyNanojoules = totalEnergyNanojoules
        self.totalDiskReadBytes = totalDiskReadBytes
        self.totalDiskWriteBytes = totalDiskWriteBytes
        self.totalPageins = totalPageins
        self.peakResidentBytes = peakResidentBytes
        self.samplesCovered = samplesCovered
        self.score = score
    }
}
