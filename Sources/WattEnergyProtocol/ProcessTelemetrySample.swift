import Foundation

public enum ProcessTelemetryConfiguration {
    public static let maximumTasks=16384
    public static let maximumOutputBytes=16*1024*1024
    public static let minimumCaptureInterval:TimeInterval=1
}

// Cumulative native counters, not interval deltas. The recorder computes deltas
// only between matching process lifetimes and fresh, monotonically timed samples.
public struct ProcessTelemetryTask:Codable,Sendable {
    public let pid:Int32
    public let parent:Int32
    public let start:UInt64
    public let name:String
    public let uid:UInt32
    public let metricsAvailable:Bool
    public let cpuNanoseconds:UInt64
    public let memory:UInt64
    public let readBytes:UInt64
    public let writtenBytes:UInt64
    public let energyNanojoules:UInt64?
    public let idleWakeups:UInt64?
    public let interruptWakeups:UInt64?

    public init(pid:Int32,parent:Int32,start:UInt64,name:String,uid:UInt32,metricsAvailable:Bool,
                cpuNanoseconds:UInt64,memory:UInt64,readBytes:UInt64,writtenBytes:UInt64,
                energyNanojoules:UInt64?=nil,idleWakeups:UInt64?=nil,interruptWakeups:UInt64?=nil) {
        self.pid=pid;self.parent=parent;self.start=start;self.name=name;self.uid=uid;self.metricsAvailable=metricsAvailable
        self.cpuNanoseconds=cpuNanoseconds;self.memory=memory;self.readBytes=readBytes;self.writtenBytes=writtenBytes
        self.energyNanojoules=energyNanojoules;self.idleWakeups=idleWakeups;self.interruptWakeups=interruptWakeups
    }
}

public struct ProcessTelemetrySample:Codable,Sendable {
    public let id:String
    public let sampledAt:Date
    public let uptime:TimeInterval
    public let tasks:[ProcessTelemetryTask]
    public let denied:Int

    public init(id:String=UUID().uuidString,sampledAt:Date,uptime:TimeInterval,tasks:[ProcessTelemetryTask],denied:Int) {
        self.id=id;self.sampledAt=sampledAt;self.uptime=uptime;self.tasks=tasks;self.denied=denied
    }

    public func validate() throws {
        guard UUID(uuidString:id) != nil,sampledAt.timeIntervalSince1970.isFinite,sampledAt.timeIntervalSince1970>0,
              uptime.isFinite,uptime>0,!tasks.isEmpty,tasks.count<=ProcessTelemetryConfiguration.maximumTasks,
              denied>=0,denied<=ProcessTelemetryConfiguration.maximumTasks else {throw ProcessTelemetryError.invalidSample}
        var seen=Set<Int32>()
        for task in tasks {
            guard task.pid>0,task.parent>=0,task.parent != task.pid,seen.insert(task.pid).inserted,
                  task.start>0,Double(task.start)/1e6<=sampledAt.timeIntervalSince1970,
                  !task.name.isEmpty,task.name.utf8.count<=512,
                  !task.name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else {
                throw ProcessTelemetryError.invalidTask
            }
            if !task.metricsAvailable {
                guard task.cpuNanoseconds==0,task.memory==0,task.readBytes==0,task.writtenBytes==0,
                      task.energyNanojoules==nil,task.idleWakeups==nil,task.interruptWakeups==nil else {
                    throw ProcessTelemetryError.invalidTask
                }
            }
        }
    }

    public static func decode(_ data:Data) throws -> Self {
        guard data.count<=ProcessTelemetryConfiguration.maximumOutputBytes else {throw ProcessTelemetryError.tooLarge}
        let value=try JSONDecoder().decode(Self.self,from:data)
        try value.validate()
        return value
    }
}

public enum ProcessTelemetryError:Error,LocalizedError {
    case invalidSample,invalidTask,tooLarge
    public var errorDescription:String? {
        switch self {
        case .invalidSample:return "The privileged collector returned an invalid process capture."
        case .invalidTask:return "The privileged collector returned an invalid process identity or counters."
        case .tooLarge:return "The privileged process capture exceeded its size limit."
        }
    }
}
