import Foundation
import SwiftUI

// Explicit illustrative samples, isolated from the user's recording database and preferences.
@MainActor func renderExplorerPreview(to path:String,applications:Bool=false) throws {
    let end=Date(timeIntervalSince1970:1793914380)
    let start=end.addingTimeInterval(-120)
    let names=["ninja","clang","clang","ld","dsymutil","Build service","mds_stores","WindowServer","Editor","Watt recorder"]
    let ids:[Int32]=[14080,14092,14094,14112,14118,502,233,179,1244,7840]
    let baseCPU:[Double]=[7.8,201.3,382,68.4,21.4,44.8,19.2,13.1,28.6,0.8]
    let memory:[UInt64]=[33_000_000,1_140_000_000,1_830_000_000,480_000_000,315_000_000,690_000_000,410_000_000,440_000_000,1_280_000_000,74_000_000]
    let frames:[Frame]=(0...24).map {index in
        let phase=sin(Double(index)/24*Double.pi)
        let time=start.addingTimeInterval(Double(index)*5)
        let processes:[ProcessRow]=names.enumerated().map {offset,name in
            let cpu=baseCPU[offset]*(0.35+phase*0.65)
            let watts=cpu/100*0.67
            let footprint=memory[offset]+UInt64(phase*Double(memory[offset])*0.12)
            return ProcessRow(pid:ids[offset],parent:offset>0 && offset<5 ? ids[0] : 1,
                              start:UInt64(start.addingTimeInterval(-30).timeIntervalSince1970*1_000_000),name:name,cpu:cpu,memory:footprint,growth:Int64(phase*4_000_000),
                              read:UInt64(Double(offset<5 ? 160_000_000 : 2_000_000)*(0.2+phase)),written:UInt64(Double(offset<5 ? 40_000_000 : 500_000)*(0.2+phase)),
                              energyNanojoules:UInt64(watts*5*1_000_000_000),
                              applicationID:offset<5 ? "com.example.DeveloperTools" : offset==8 ? "com.example.Editor" : offset==9 ? "com.grahamgilbert.Watt" : nil,
                              applicationName:offset<5 ? "Developer Tools" : offset==8 ? "Editor" : offset==9 ? "Watt" : nil)
        }
        return Frame(time:time,cpu:17+phase*76,memory:UInt64(21.4*1073741824+phase*900_000_000),compressed:2_100_000_000,swap:0,download:9_400_000,upload:1_300_000,processes:processes,denied:12,
                     segment:"illustrative-build",elapsed:5,cadence:5,memoryAccounting:"app-wired-compressed",processCPUAccounting:"mach-timebase-to-nanoseconds")
    }
    let monitor=Monitor(previewFrames:frames)
    let range=DateInterval(start:start,duration:120)
    monitor.historyFrames=frames;monitor.historyRange=range;monitor.historyBounds=range
    monitor.selected=start.addingTimeInterval(65)
    monitor.historySummaries=HistoryAnalysis.summarize(frames,range:range,gaps:[])
    let controls=ProcessExplorerControls()
    controls.center=start.addingTimeInterval(60);controls.duration=120;controls.selection=frames[0].processes[2].id
    controls.mode="Interval summary"
    if applications {
        controls.scope="Applications";controls.sort="CPU energy"
        controls.applicationSelection="app:com.example.DeveloperTools"
        controls.applicationSummaries=AppPowerGrouping.summarize(frames,range:range,gaps:[])
    }
    try renderHostedView(ProcessExplorerView(monitor:monitor,controls:controls),size:NSSize(width:1440,height:900),to:path)
}
