import Foundation
import CTelemetry
import WattEnergyProtocol

// Fixed native reads only. Admission is synchronous so clients cannot build an
// unbounded worker backlog; at most one capture runs, no more than once a second.
final class NativeProcessCapture {
    private let queue=DispatchQueue(label:"com.grahamgilbert.Watt.Process.capture",qos:.utility)
    private let lock=NSLock()
    private var owners=Set<UUID>()
    private var busy=false
    private var lastCapture:TimeInterval?
    private let encoder=JSONEncoder()

    func connected(owner:UUID) {lock.lock();owners.insert(owner);lock.unlock()}
    func cancel(owner:UUID) {lock.lock();owners.remove(owner);lock.unlock()}

    func capture(owner:UUID,reply:@escaping (Data?,String?)->Void) {
        let now=ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard owners.contains(owner) else {lock.unlock();reply(nil,"Process client disconnected.");return}
        guard !busy,lastCapture.map({now-$0>=ProcessTelemetryConfiguration.minimumCaptureInterval}) ?? true else {
            lock.unlock();reply(nil,"A privileged process capture is already running or was requested too recently.");return
        }
        busy=true;lastCapture=now;lock.unlock()
        queue.async { [self] in
            let data:Data?,failure:String?
            do {
                var buffer=[WattProcess](repeating:WattProcess(),count:ProcessTelemetryConfiguration.maximumTasks)
                var denied:Int32=0
                let count=watt_processes(&buffer,Int32(buffer.count),&denied)
                guard count>=0 else {throw ProcessTelemetryError.invalidSample}
                let tasks=buffer.prefix(Int(count)).map {process -> ProcessTelemetryTask in
                    var bytes=process.name
                    let rawName=withUnsafePointer(to:&bytes) {pointer in
                        pointer.withMemoryRebound(to:CChar.self,capacity:256) {String(cString:$0)}
                    }
                    // A process controls its own name. Keep an unusual name from
                    // invalidating the entire inventory or injecting UI controls.
                    let cleaned=String(String.UnicodeScalarView(rawName.unicodeScalars.filter {
                        !CharacterSet.controlCharacters.contains($0)
                    }.prefix(128)))
                    let name=cleaned.isEmpty ? "Process \(process.pid)" : cleaned
                    let available=process.metrics_available != 0
                    return ProcessTelemetryTask(pid:process.pid,parent:process.parent,start:process.start,name:name,uid:process.uid,
                        metricsAvailable:available,cpuNanoseconds:available ? process.cpu : 0,memory:available ? process.footprint : 0,
                        readBytes:available ? process.read : 0,writtenBytes:available ? process.written : 0,
                        energyNanojoules:available && process.energy_available != 0 ? process.energy_nj : nil,
                        idleWakeups:available && process.wakeups_available != 0 ? process.idle_wakeups : nil,
                        interruptWakeups:available && process.wakeups_available != 0 ? process.interrupt_wakeups : nil)
                }
                let sample=ProcessTelemetrySample(sampledAt:Date(),uptime:ProcessInfo.processInfo.systemUptime,tasks:tasks,denied:Int(denied))
                try sample.validate()
                let encoded=try encoder.encode(sample)
                guard encoded.count<=ProcessTelemetryConfiguration.maximumOutputBytes else {throw ProcessTelemetryError.tooLarge}
                data=encoded;failure=nil
            } catch {data=nil;failure=error.localizedDescription}
            lock.lock();let connected=owners.contains(owner);busy=false;lock.unlock()
            if connected {reply(data,failure)} else {reply(nil,"Process client disconnected.")}
        }
    }
}
