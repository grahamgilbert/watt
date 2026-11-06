import Foundation
import CoreFoundation

public enum EnergyServiceConfiguration {
    public static let serviceName="com.grahamgilbert.Watt.Energy"
    public static let helperIdentifier="com.grahamgilbert.Watt.EnergyHelper"
    public static let appIdentifier="com.grahamgilbert.Watt"
    public static let plistName="com.grahamgilbert.Watt.Energy.plist"
    public static let maximumOutputBytes=16*1024*1024
}
@objc public protocol WattEnergyServiceProtocol {
    // The client cannot select a command, arguments, interval, or output path.
    func capture(withReply reply:@escaping (Data?,String?)->Void)
    // Available in helpers with native process telemetry support. Older helpers
    // reject this selector; clients must handle the XPC error and use local data.
    func captureProcesses(withReply reply:@escaping (Data?,String?)->Void)
}
public struct EnergyImpactTask:Codable,Identifiable,Sendable {
    public let pid:Int32
    public let name:String
    public let energyImpact:Double?
    public let energyImpactPerSecond:Double?
    public let responsiblePID:Int32?
    public let parentPID:Int32?
    public let processStartMicroseconds:UInt64?
    public var id:Int32 {pid}
    public init(pid:Int32,name:String,energyImpact:Double?,energyImpactPerSecond:Double?,responsiblePID:Int32?=nil,parentPID:Int32?=nil,processStartMicroseconds:UInt64?=nil) {
        self.pid=pid;self.name=name;self.energyImpact=energyImpact;self.energyImpactPerSecond=energyImpactPerSecond
        self.responsiblePID=responsiblePID;self.parentPID=parentPID;self.processStartMicroseconds=processStartMicroseconds
    }
}
public struct EnergyImpactSample:Codable,Identifiable,Sendable {
    public let id:String
    public let startedAt:Date
    public let endedAt:Date
    public let tasks:[EnergyImpactTask]
    // One index per immutable capture avoids scanning the full process inventory for every table row.
    private let taskIndices:[Int32:Int]
    private enum CodingKeys:String,CodingKey {case id,startedAt,endedAt,tasks}
    public init(id:String=UUID().uuidString,startedAt:Date,endedAt:Date,tasks:[EnergyImpactTask]) {
        self.id=id;self.startedAt=startedAt;self.endedAt=endedAt;self.tasks=tasks
        taskIndices=Dictionary(tasks.enumerated().map {($0.element.pid,$0.offset)},uniquingKeysWith:{first,_ in first})
    }
    public init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        self.init(id:try values.decode(String.self,forKey:.id),startedAt:try values.decode(Date.self,forKey:.startedAt),
                  endedAt:try values.decode(Date.self,forKey:.endedAt),tasks:try values.decode([EnergyImpactTask].self,forKey:.tasks))
    }
    public var hasEnergyValues:Bool {tasks.contains {$0.energyImpact != nil || $0.energyImpactPerSecond != nil}}
    public func task(forPID pid:Int32,processStart:Date?,at date:Date,maximumAge:TimeInterval=5)->EnergyImpactTask? {
        guard let processStart,maximumAge.isFinite,maximumAge>=0,endedAt<=date,
              date.timeIntervalSince(endedAt)<=maximumAge,processStart<=startedAt else {return nil}
        guard let index=taskIndices[pid] else {return nil}
        let task=tasks[index]
        if let observed=task.processStartMicroseconds,
           abs(Double(observed)/1e6-processStart.timeIntervalSince1970)>=0.00001 {
            return nil
        }
        return task
    }
    public func validate() throws {
        guard startedAt.timeIntervalSince1970.isFinite,endedAt.timeIntervalSince1970.isFinite,
              startedAt<=endedAt,endedAt.timeIntervalSince(startedAt)<=15,tasks.count<=16384 else {throw EnergyImpactParseError.invalidSample}
        var seen=Set<Int32>()
        for task in tasks {
            guard task.pid>=0,seen.insert(task.pid).inserted,!task.name.isEmpty,task.name.utf8.count<=512,
                  !task.name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}),
                  [task.energyImpact,task.energyImpactPerSecond].allSatisfy({$0.map {$0.isFinite && $0>=0} ?? true}),
                  [task.parentPID,task.responsiblePID].allSatisfy({$0.map {$0>=0} ?? true}) else {throw EnergyImpactParseError.invalidTask}
            if let start=task.processStartMicroseconds,(start==0 || Double(start)/1e6>startedAt.timeIntervalSince1970) {throw EnergyImpactParseError.invalidTask}
        }
    }
}
public enum EnergyImpactParseError:Error,LocalizedError {
    case tooLarge,invalidSample,invalidTask,missingTasks
    public var errorDescription:String? {
        switch self {
        case .tooLarge:return "Apple energy output exceeded the size limit."
        case .invalidSample:return "Apple energy output did not contain a valid capture interval."
        case .invalidTask:return "Apple energy output contained invalid process measurements."
        case .missingTasks:return "Apple energy output did not contain a task sample."
        }
    }
}
public enum EnergyImpactParser {
    public static func parse(_ data:Data,startedAt:Date,endedAt:Date) throws -> EnergyImpactSample {
        guard data.count<=EnergyServiceConfiguration.maximumOutputBytes else {throw EnergyImpactParseError.tooLarge}
        var selected:[String:Any]?
        for part in data.split(separator:0,omittingEmptySubsequences:true) {
            guard let value=try? PropertyListSerialization.propertyList(from:Data(part),format:nil) as? [String:Any] else {continue}
            if value["tasks"] != nil {selected=value}
        }
        guard let root=selected,let rawTasks=root["tasks"] as? [[String:Any]],rawTasks.count<=16384 else {throw EnergyImpactParseError.missingTasks}
        let tasks=try rawTasks.compactMap {raw -> EnergyImpactTask? in
            // powermetrics includes a synthetic exited-process aggregate, not an inspectable PID.
            if let pid=raw["pid"] as? NSNumber,CFGetTypeID(pid) != CFBooleanGetTypeID(),
               pid.doubleValue == -1,raw["name"] as? String == "DEAD_TASKS" {return nil}
            guard let pid=try integer(raw["pid"]),let name=raw["name"] as? String else {throw EnergyImpactParseError.invalidTask}
            return EnergyImpactTask(pid:pid,name:name,energyImpact:try number(raw["energy_impact"]),energyImpactPerSecond:try number(raw["energy_impact_per_s"]),responsiblePID:try integer(raw["responsible_pid"],unknownSentinel:true),parentPID:try integer(raw["parent_pid"] ?? raw["ppid"],unknownSentinel:true))
        }
        let sample=EnergyImpactSample(startedAt:startedAt,endedAt:endedAt,tasks:tasks)
        try sample.validate();return sample
    }
    private static func number(_ value:Any?) throws -> Double? {
        guard let value else {return nil}
        guard let number=value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID() else {throw EnergyImpactParseError.invalidTask}
        let result=number.doubleValue
        guard result.isFinite,result>=0 else {throw EnergyImpactParseError.invalidTask}
        return result
    }
    private static func integer(_ value:Any?,unknownSentinel:Bool=false) throws -> Int32? {
        guard let value else {return nil}
        guard let number=value as? NSNumber,CFGetTypeID(number) != CFBooleanGetTypeID() else {throw EnergyImpactParseError.invalidTask}
        let result=number.doubleValue
        if unknownSentinel,result == -1 {return nil}
        guard result.isFinite,result>=0,result<=Double(Int32.max),result.rounded()==result else {throw EnergyImpactParseError.invalidTask}
        return Int32(result)
    }
}
public final class EnergyImpactCache:@unchecked Sendable {
    public static let shared=EnergyImpactCache()
    private let lock=NSLock()
    private var sample:EnergyImpactSample?
    public init() {}
    public func store(_ value:EnergyImpactSample) {
        guard (try? value.validate()) != nil else {clear();return}
        lock.lock();sample=value;lock.unlock()
    }
    public func clear() {lock.lock();sample=nil;lock.unlock()}
    public func latest(maxAge:TimeInterval=5,now:Date=Date())->EnergyImpactSample? {
        guard maxAge.isFinite,maxAge>=0 else {return nil}
        lock.lock();let value=sample;lock.unlock()
        guard let value,value.endedAt<=now,now.timeIntervalSince(value.endedAt)<=maxAge else {return nil}
        return value
    }
}
