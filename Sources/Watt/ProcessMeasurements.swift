import CTelemetry
import Foundation
import WattEnergyProtocol

enum ProcessMeasurements {
    static func row(current:WattProcess,previous:WattProcess?,elapsed:TimeInterval?,source:String)->ProcessRow {
        let available=current.metrics_available != 0
        let old=previous.flatMap {p in
            p.pid==current.pid && p.start==current.start && p.metrics_available != 0 && available ? p : nil
        }
        let interval=elapsed.flatMap {$0.isFinite && $0>0 ? $0 : nil}
        let wakeups=old.flatMap {current.wakeups_available != 0 && $0.wakeups_available != 0 ? $0 : nil}
        let cpu=old.flatMap {delta(current.cpu,$0.cpu)}.flatMap {value in interval.map {Double(value)/1e9/$0*100}}
        var name=current.name
        let label=withUnsafePointer(to:&name) {ptr in
            ptr.withMemoryRebound(to:CChar.self,capacity:256) {String(cString:$0)}
        }
        return ProcessRow(pid:current.pid,parent:current.parent,start:current.start,name:label,cpu:cpu,
                          memory:available ? current.footprint : nil,
                          growth:old.flatMap {growth(current.footprint,$0.footprint)},
                          read:interval == nil ? nil : old.flatMap {delta(current.read,$0.read)},
                          written:interval == nil ? nil : old.flatMap {delta(current.written,$0.written)},
                          energyNanojoules:interval == nil ? nil : processEnergyDelta(current:current,previous:old),
                          idleWakeups:interval == nil ? nil : wakeups.flatMap {delta(current.idle_wakeups,$0.idle_wakeups)},
                          interruptWakeups:interval == nil ? nil : wakeups.flatMap {delta(current.interrupt_wakeups,$0.interrupt_wakeups)},
                          userID:current.uid,metricSource:available ? source : "restricted")
    }
    private static func growth(_ current:UInt64,_ old:UInt64)->Int64? {
        if current>=old {return Int64(exactly:current-old)}
        return Int64(exactly:old-current).map {-($0)}
    }
    static func counters(_ task:ProcessTelemetryTask)->WattProcess {
        var p=WattProcess()
        p.pid=task.pid;p.parent=task.parent;p.start=task.start;p.uid=task.uid
        p.metrics_available=task.metricsAvailable ? 1 : 0
        p.cpu=task.cpuNanoseconds;p.footprint=task.memory;p.read=task.readBytes;p.written=task.writtenBytes
        p.energy_available=task.energyNanojoules == nil ? 0 : 1;p.energy_nj=task.energyNanojoules ?? 0
        p.idle_wakeups=task.idleWakeups ?? 0;p.interrupt_wakeups=task.interruptWakeups ?? 0
        p.wakeups_available=task.idleWakeups != nil && task.interruptWakeups != nil ? 1 : 0
        let name=Array(task.name.utf8CString.prefix(255))
        withUnsafeMutablePointer(to:&p.name) {ptr in
            ptr.withMemoryRebound(to:CChar.self,capacity:256) {buffer in
                for (index,character) in name.enumerated() {buffer[index]=character}
            }
        }
        return p
    }
}
