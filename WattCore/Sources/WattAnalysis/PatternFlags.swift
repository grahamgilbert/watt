import Foundation

public struct PatternFlags: Sendable, Hashable, Codable {
    public var correlatedWriterReader: CorrelatedPair?
    public var thermalThrottle: Bool
    public var fanSpike: Bool
    public var memoryPressureSpike: Bool

    public init(
        correlatedWriterReader: CorrelatedPair? = nil,
        thermalThrottle: Bool = false,
        fanSpike: Bool = false,
        memoryPressureSpike: Bool = false
    ) {
        self.correlatedWriterReader = correlatedWriterReader
        self.thermalThrottle = thermalThrottle
        self.fanSpike = fanSpike
        self.memoryPressureSpike = memoryPressureSpike
    }

    public struct CorrelatedPair: Sendable, Hashable, Codable {
        public var writer: ProcessIdentity
        public var reader: ProcessIdentity
        public var writerBytes: UInt64
        public var readerBytes: UInt64

        public init(
            writer: ProcessIdentity,
            reader: ProcessIdentity,
            writerBytes: UInt64,
            readerBytes: UInt64
        ) {
            self.writer = writer
            self.reader = reader
            self.writerBytes = writerBytes
            self.readerBytes = readerBytes
        }
    }

    public struct ProcessIdentity: Sendable, Hashable, Codable {
        public var pid: Int32
        public var name: String
        public init(pid: Int32, name: String) {
            self.pid = pid
            self.name = name
        }
    }
}
