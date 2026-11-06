import AppKit
import SwiftUI
import Darwin
import WattEnergyProtocol

// A deterministic, isolated workload. No recording database, system sampling or helper registration.
// Keep this harness identical in the baseline and candidate builds used by the CI gate.
@MainActor func runUIPerformanceBenchmark() {
    func cpuSeconds()->Double {
        var usage=rusage();getrusage(RUSAGE_SELF,&usage)
        return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6
    }
    func residentBytes()->UInt64 {
        var info=mach_task_basic_info()
        var count=mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<integer_t>.size)
        let result=withUnsafeMutablePointer(to:&info) {pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
                task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count)
            }
        }
        return result==KERN_SUCCESS ? UInt64(info.resident_size) : 0
    }
    let origin=Date(timeIntervalSince1970:1_800_000_000)
    let processStart=UInt64((origin.timeIntervalSince1970-60)*1e6)
    func frame(_ index:Int)->Frame {
        let time=origin.addingTimeInterval(Double(index)*5)
        let rows=(0..<800).map {offset in
            ProcessRow(pid:Int32(offset+1),parent:offset>0 ? 1 : 0,start:processStart,name:"Fixture process \(offset)",
                       cpu:Double((offset+index)%100),memory:UInt64(30_000_000+offset*1000),growth:1024,
                       read:UInt64(offset*1024),written:UInt64(offset*512),energyNanojoules:UInt64(offset*1_000_000))
        }
        let energy=EnergyImpactSample(id:"fixture-\(index)",startedAt:time.addingTimeInterval(-1),endedAt:time,tasks:rows.map {
            EnergyImpactTask(pid:$0.pid,name:$0.name,energyImpact:nil,energyImpactPerSecond:Double($0.pid%30),processStartMicroseconds:$0.start)
        })
        return Frame(time:time,cpu:Double(index%80),memory:16_000_000_000,compressed:1_000_000_000,swap:0,
                     download:100_000,upload:20_000,processes:rows,denied:0,segment:"fixture",elapsed:5,cadence:5,
                     memoryAccounting:"app-wired-compressed",processCPUAccounting:"mach-timebase-to-nanoseconds",energyImpact:energy)
    }
    _=NSApplication.shared
    let size=NSSize(width:1440,height:900)
    let window=NSWindow(contentRect:NSRect(origin:NSPoint(x:-10000,y:-10000),size:size),styleMask:[],backing:.buffered,defer:false)
    window.isReleasedWhenClosed=false;window.appearance=NSAppearance(named:.darkAqua)
    defer {window.contentView=nil;window.close()}
    let monitor=Monitor(previewFrames:(0..<120).map(frame))
    let controls=ProcessExplorerControls();controls.selection=monitor.frames[0].processes[1].id
    let host=NSHostingView(rootView:ProcessExplorerView(monitor:monitor,controls:controls).environment(\.colorScheme,.dark).frame(width:size.width,height:size.height))
    host.frame=NSRect(origin:.zero,size:size);window.contentView=host
    func update(_ index:Int) {
        autoreleasepool {
            let next=frame(index)
            monitor.frames=Array((monitor.frames+[next]).suffix(120));monitor.liveFrame=next;monitor.selected=next.time
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until:Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            if let bitmap=host.bitmapImageRepForCachingDisplay(in:host.bounds) {host.cacheDisplay(in:host.bounds,to:bitmap)}
        }
    }
    update(120);update(121)
    let updates=12,start=cpuSeconds(),wall=ProcessInfo.processInfo.systemUptime
    var peak=residentBytes()
    for index in 122..<(122+updates) {update(index);peak=max(peak,residentBytes())}
    let cpu=cpuSeconds()-start
    let report:[String:Any]=["schema":1,"workload":"explorer-render-v1","updates":updates,"warmup_updates":2,"frame_count":120,"process_count":800,
        "cpu_ms_per_update":cpu*1000/Double(updates),"cpu_seconds":cpu,"elapsed_seconds":ProcessInfo.processInfo.systemUptime-wall,
        "resident_bytes":residentBytes(),"peak_resident_bytes":peak,
        "scope":"Offscreen Explorer updates with fixed inventories and energy readings; excludes recorder, helper and real battery life."]
    do {print(String(data:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]),encoding:.utf8)!)}
    catch {fputs("UI benchmark failed: \(error)\n",stderr);exit(1)}
}
