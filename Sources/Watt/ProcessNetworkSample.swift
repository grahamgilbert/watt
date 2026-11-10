import Foundation

enum ProcessNetworkStatus:String,Codable {
    case available,waiting,unavailable,unsupported
}

// A process-network capture owns its interval. It is deliberately separate from
// Frame.elapsed: the passive adapter can finish between recorder samples.
struct ProcessNetworkSample:Codable,Identifiable,Equatable {
    var id:String
    var startedAt:Date
    var endedAt:Date
    var elapsed:Double
    var tasks:[ProcessNetworkTask]
    var status:ProcessNetworkStatus
    var source:String
    var unmatchedProcesses:Int
    var error:String?
    var isAvailable:Bool {status == .available}

    func isFresh(at time:Date)->Bool {
        isAvailable && elapsed.isFinite && elapsed>0 && endedAt>=startedAt
            && endedAt<=time.addingTimeInterval(0.05)
            && time.timeIntervalSince(endedAt)<=max(15,elapsed*2.5)
    }
}

struct ProcessNetworkTask:Codable,Identifiable,Equatable {
    var pid:Int32
    var parent:Int32
    var start:UInt64
    var name:String
    var applicationID:String?
    var applicationName:String?
    var userID:UInt32?
    var receivedBytes:UInt64?
    var sentBytes:UInt64?
    var id:String {"\(pid):\(start)"}
    func downloadRate(elapsed:Double)->Double? {rate(receivedBytes,elapsed:elapsed)}
    func uploadRate(elapsed:Double)->Double? {rate(sentBytes,elapsed:elapsed)}
    private func rate(_ bytes:UInt64?,elapsed:Double)->Double? {
        guard let bytes,elapsed.isFinite,elapsed>0 else {return nil}
        return Double(bytes)/elapsed
    }
}

struct ProcessNetworkRawTask:Equatable {
    var pid:Int32
    var receivedBytes:UInt64?
    var sentBytes:UInt64?
}
struct ProcessNetworkRawCapture:Equatable {
    var id:String
    var startedAt:Date
    var endedAt:Date
    var elapsed:Double
    var tasks:[ProcessNetworkRawTask]
}

enum ProcessNetworkParseError:Error {
    case outputLimit,invalidHeader,invalidRow,invalidInterval
}

// nettop -P -L0 -d emits a CSV header for each update. The first batch is
// cumulative and discarded. Only the next header proves that a batch is whole,
// so a published interval is intentionally one adapter interval behind Now.
struct ProcessNetworkCSVParser {
    static let maximumBufferedBytes=128*1024
    static let maximumLineBytes=4096
    static let maximumRows=16_384
    static let maximumBatchBytes=2*1024*1024
    private var buffer=Data()
    private var previousHeader:(wall:Date,uptime:Double)?
    private var batch:ProcessNetworkRawCapture?
    private var rows:[ProcessNetworkRawTask]=[]
    private var seen=Set<Int32>()
    private var batchBytes=0
    private let sessionID:String
    private var sequence=0
    init(sessionID:String=UUID().uuidString) {self.sessionID=sessionID}

    mutating func consume(_ data:Data,at wall:Date,uptime:Double,cadence:Double) throws -> [ProcessNetworkRawCapture] {
        guard data.count<=Self.maximumBufferedBytes,buffer.count+data.count<=Self.maximumBufferedBytes else {throw ProcessNetworkParseError.outputLimit}
        buffer.append(data)
        var completed:[ProcessNetworkRawCapture]=[]
        var consumed=0
        defer {if consumed>0 {buffer.removeFirst(consumed)}}
        while let newline=buffer[buffer.index(buffer.startIndex,offsetBy:consumed)...].firstIndex(of:10) {
            let lineStart=buffer.index(buffer.startIndex,offsetBy:consumed)
            let length=buffer.distance(from:lineStart,to:newline)
            guard length<=Self.maximumLineBytes else {throw ProcessNetworkParseError.outputLimit}
            let lineData=buffer[lineStart..<newline]
            guard let rawLine=String(data:lineData,encoding:.utf8) else {throw ProcessNetworkParseError.invalidRow}
            consumed+=length+1
            let line=rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            guard !line.isEmpty else {continue}
            batchBytes+=length
            guard batchBytes<=Self.maximumBatchBytes else {throw ProcessNetworkParseError.outputLimit}
            let columns=try Self.csvFields(line)
            if columns.first=="" {
                guard columns==["","bytes_in","bytes_out",""] || columns==["","bytes_in","bytes_out"] else {throw ProcessNetworkParseError.invalidHeader}
                if var complete=batch {
                    complete.tasks=rows
                    completed.append(complete)
                }
                sequence+=1
                if let previousHeader {
                    let elapsed=uptime-previousHeader.uptime
                    // Buffered multi-interval output or sleep must not turn into
                    // a tiny denominator and an enormous traffic spike.
                    guard elapsed.isFinite,elapsed>=max(0.25,cadence*0.5),elapsed<=max(15,cadence*2.5),
                          abs(wall.timeIntervalSince(previousHeader.wall)-elapsed)<=2 else {throw ProcessNetworkParseError.invalidInterval}
                    batch=ProcessNetworkRawCapture(id:"\(sessionID):\(sequence)",startedAt:previousHeader.wall,
                                                  endedAt:wall,elapsed:elapsed,tasks:[])
                } else {batch=nil}
                previousHeader=(wall,uptime);rows=[];seen=[];batchBytes=0
                continue
            }
            guard previousHeader != nil else {throw ProcessNetworkParseError.invalidHeader}
            guard columns.count==3 || (columns.count==4 && columns[3].isEmpty),
                  let separator=columns[0].lastIndex(of:"."),
                  let pid=Int32(columns[0][columns[0].index(after:separator)...]),pid>0 else {throw ProcessNetworkParseError.invalidRow}
            guard rows.count<Self.maximumRows,seen.insert(pid).inserted else {throw ProcessNetworkParseError.outputLimit}
            func counter(_ text:String)throws->UInt64? {
                if text.isEmpty || text=="?" || text=="-" {return nil}
                guard !text.hasPrefix("-"),let value=UInt64(text) else {throw ProcessNetworkParseError.invalidRow}
                return value
            }
            rows.append(try ProcessNetworkRawTask(pid:pid,receivedBytes:counter(columns[1]),sentBytes:counter(columns[2])))
        }
        guard buffer.count-consumed<=Self.maximumLineBytes else {throw ProcessNetworkParseError.outputLimit}
        return completed
    }

    private static func csvFields(_ line:String)throws->[String] {
        var fields:[String]=[],value="",quoted=false,closedQuote=false
        var iterator=line.makeIterator()
        while let character=iterator.next() {
            if quoted {
                if character=="\"" {quoted=false;closedQuote=true} else {value.append(character)}
            } else if character=="," {
                fields.append(value);value="";closedQuote=false
            } else if character=="\"" {
                if closedQuote {value.append("\"");quoted=true;closedQuote=false}
                else {guard value.isEmpty else {throw ProcessNetworkParseError.invalidRow};quoted=true}
            } else {
                guard !closedQuote else {throw ProcessNetworkParseError.invalidRow}
                value.append(character)
            }
            guard fields.count<=4 else {throw ProcessNetworkParseError.invalidRow}
        }
        guard !quoted else {throw ProcessNetworkParseError.invalidRow}
        fields.append(value);return fields
    }
}

// Identity comes from Watt's existing process inventory, never a truncated CSV
// display name. Keep recent exits long enough to retain their final interval.
struct ProcessNetworkIdentityCache {
    private struct Identity {var process:ProcessRow;var seenAt:Date}
    private var identities:[Int32:Identity]=[:]
    mutating func observe(_ processes:[ProcessRow],at time:Date,cadence:Double) {
        let retention=max(30,cadence*4)
        identities=identities.filter {time.timeIntervalSince($0.value.seenAt)<=retention}
        for process in processes where process.pid>0 && process.start>0 {
            if identities[process.pid]==nil && identities.count>=ProcessNetworkCSVParser.maximumRows {
                if let oldest=identities.min(by:{$0.value.seenAt<$1.value.seenAt})?.key {identities.removeValue(forKey:oldest)}
            }
            identities[process.pid]=Identity(process:process,seenAt:time)
        }
    }
    func resolve(_ raw:ProcessNetworkRawCapture)->ProcessNetworkSample {
        var unmatched=0
        let tasks=raw.tasks.compactMap {task->ProcessNetworkTask? in
            guard let identity=identities[task.pid],identity.process.start>0 else {unmatched+=1;return nil}
            let p=identity.process
            // A reused PID or newly born task cannot inherit an earlier task's
            // bytes. Its first partial interval stays unavailable.
            let start=Date(timeIntervalSince1970:Double(p.start)/1e6)
            guard start<=raw.startedAt else {unmatched+=1;return nil}
            return ProcessNetworkTask(pid:p.pid,parent:p.parent,start:p.start,name:p.name,
                                      applicationID:p.applicationID,applicationName:p.applicationName,userID:p.userID,
                                      receivedBytes:task.receivedBytes,sentBytes:task.sentBytes)
        }
        return ProcessNetworkSample(id:raw.id,startedAt:raw.startedAt,endedAt:raw.endedAt,elapsed:raw.elapsed,
                                    tasks:tasks,status:.available,source:"nettop-external-tcp-udp",unmatchedProcesses:unmatched,error:nil)
    }
    mutating func reset() {identities=[:]}
}
