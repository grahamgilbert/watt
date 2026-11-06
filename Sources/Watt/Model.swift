import Foundation
import Combine
import AppKit
import CTelemetry
import WattEnergyProtocol

struct ProcessRow: Identifiable, Codable {
    var pid: Int32; var parent: Int32; var start: UInt64; var name: String
    var cpu: Double?; var memory: UInt64; var growth: Int64?
    var read: UInt64?; var written: UInt64?
    // Deltas over the frame's measured interval. Energy is kernel-attributed CPU energy only.
    var energyNanojoules: UInt64? = nil
    var idleWakeups: UInt64? = nil
    var interruptWakeups: UInt64? = nil
    var applicationID: String? = nil
    var applicationName: String? = nil
    func cpuPowerWatts(elapsed:Double?) -> Double? {
        guard let energyNanojoules,let elapsed,elapsed.isFinite,elapsed>0 else {return nil}
        return Double(energyNanojoules)/1e9/elapsed
    }
    var id: String { "\(pid):\(start)" }
}
struct Frame: Codable, Identifiable {
    var time: Date; var cpu: Double; var memory: UInt64; var compressed: UInt64; var swap: UInt64
    var download: Double; var upload: Double; var processes: [ProcessRow]; var denied: Int
    var power: PowerReading? = nil
    var segment: String? = nil
    var elapsed: Double? = nil
    var cadence: Double? = nil
    var memoryAccounting: String? = nil
    var processCPUAccounting: String? = nil
    // Preserve the capture identity and interval; multiple frames may reference the same reading.
    var energyImpact: EnergyImpactSample? = nil
    var id: Date { time }
}
func delta(_ value: UInt64, _ previous: UInt64) -> UInt64? { value >= previous ? value - previous : nil }

// Keep availability, PID lifetime and monotonicity distinct from a measured zero delta.
func processEnergyDelta(current:WattProcess,previous:WattProcess?) -> UInt64? {
    guard let previous,current.pid==previous.pid,current.start==previous.start,
          current.energy_available != 0,previous.energy_available != 0 else {return nil}
    return delta(current.energy_nj,previous.energy_nj)
}

final class Collector {
    private(set) var failed = false
    private var previous: WattSystem?
    private var processes: [String: WattProcess] = [:]
    private var last: TimeInterval?
    private let applicationResolver=ProcessApplicationResolver()
    private var baselineStartedAt=Date()
    func sample() -> Frame? {
        failed = false
        var system = WattSystem()
        guard watt_system(&system) != 0 else { failed = true; return nil }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = last.map { now - $0 }
        var buffer = [WattProcess](repeating: WattProcess(), count: 16384)
        var denied: Int32 = 0
        let count = watt_processes(&buffer, Int32(buffer.count), &denied)
        var next: [String: WattProcess] = [:]
        let rows = buffer.prefix(max(0, Int(count))).map { p -> ProcessRow in
            let key = "\(p.pid):\(p.start)"; next[key] = p
            let old = processes[key]
            let cpu = old.flatMap { delta(p.cpu, $0.cpu) }.flatMap { value in elapsed.map { Double(value) / 1e9 / max($0, 0.001) * 100 } }
            var name = p.name
            let label = withUnsafePointer(to: &name) { ptr in ptr.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
            let application=applicationResolver.identity(for:p)
            return ProcessRow(pid:p.pid,parent:p.parent,start:p.start,name:label,cpu:cpu,memory:p.footprint,
                              growth:old.map { Int64(p.footprint)-Int64($0.footprint) },
                              read:old.flatMap { delta(p.read,$0.read) },written:old.flatMap { delta(p.written,$0.written) },
                              energyNanojoules:processEnergyDelta(current:p,previous:old),
                              idleWakeups:old.flatMap {delta(p.idle_wakeups,$0.idle_wakeups)},
                              interruptWakeups:old.flatMap {delta(p.interrupt_wakeups,$0.interrupt_wakeups)},
                              applicationID:application?.id,applicationName:application?.name)
        }
        applicationResolver.retain(processIDs:Set(next.keys))
        var cpu = 0.0, rx = 0.0, tx = 0.0
        if let old = previous, let elapsed, elapsed > 0 {
            let active = Double(delta(system.user, old.user) ?? 0) + Double(delta(system.system, old.system) ?? 0)
            let idle = Double(delta(system.idle, old.idle) ?? 0)
            cpu = active / max(1, active + idle) * 100
            rx = Double(delta(system.rx,old.rx) ?? 0)/elapsed; tx = Double(delta(system.tx,old.tx) ?? 0)/elapsed
        }
        let baseline = previous != nil
        previous=system; processes=next; last=now
        guard baseline else { return nil }
        let sampledAt=Date()
        let energyImpact=EnergyImpactCache.shared.latest(maxAge:15,now:sampledAt).flatMap { $0.startedAt>=baselineStartedAt ? $0 : nil }
        return Frame(time:sampledAt,cpu:cpu,memory:system.memory,compressed:system.compressed,swap:system.swap,
                     download:rx,upload:tx,processes:rows,denied:count < 0 ? -1 : Int(denied),power:PowerReading.read(),elapsed:elapsed,memoryAccounting:"app-wired-compressed",processCPUAccounting:"mach-timebase-to-nanoseconds",energyImpact:energyImpact)
    }
    func reset() { previous=nil; processes=[:]; last=nil;baselineStartedAt=Date() }
}

@MainActor final class Monitor: ObservableObject {
    @Published var frames:[Frame]=[]
    @Published var liveFrame:Frame?
    @Published var historyFrames:[Frame]=[]
    @Published var historyRange:DateInterval?
    @Published var historyBounds:DateInterval?
    @Published var historySummaries:[ProcessSummary]=[]
    @Published var historyLoading=false
    @Published var historyError:String?
    private var historyRequest=UUID()
    var visibleFrames:[Frame] {historyRange == nil ? frames : historyFrames}
    @Published var paused=false
    @Published var error:String?
    @Published var interval=5.0 {didSet {UserDefaults.standard.set(interval,forKey:"recording.interval");scheduleSample(after:0)}}
    @Published var selected:Date?
    @Published var gaps:[RecordingGap]=[]
    @Published var storageBytes:Int64=0
    private var sleeping=false
    private var observers:[NSObjectProtocol]=[]
    private let queue=DispatchQueue(label:"app.watt.recorder",qos:.utility)
    private var timer:Timer?
    private var collecting=false
    private nonisolated let backend=RecorderBackend()
    var current:Frame? {
        if let selected {return HistoryAnalysis.snapshot(at:selected,frames:visibleFrames,gaps:gaps)}
        return historyRange == nil ? liveFrame : nil
    }
    func returnToLive() {historyRequest=UUID();historyRange=nil;historyFrames=[];historySummaries=[];selected=nil;historyLoading=false;historyError=nil}
    func releaseHistoryDetails() {
        historyRequest=UUID()
        if !historyFrames.isEmpty {historyFrames=[]}
        if !historySummaries.isEmpty {historySummaries=[]}
        if historyLoading {historyLoading=false}
    }
    func restoreHistoryDetailsIfNeeded() {
        guard let range=historyRange,historyFrames.isEmpty,!historyLoading else {return}
        let cursor=selected
        loadHistory(center:range.start.addingTimeInterval(range.duration/2),duration:range.duration)
        selected=cursor
    }
    func loadHistory(center:Date,duration:TimeInterval) {
        let range=DateInterval(start:center.addingTimeInterval(-duration/2),duration:duration)
        let request=UUID();historyRequest=request;historyRange=range;selected=center
        historyFrames=[];historySummaries=[];historyLoading=true;historyError=nil
        queue.async { [self] in
            do {
                guard let store=backend.store else {throw NSError(domain:"Watt",code:1,userInfo:[NSLocalizedDescriptionKey:"History database is unavailable"])}
                let frames=try store.frames(in:range)
                let gaps=try store.gaps()
                let summaries=HistoryAnalysis.summarize(frames,range:range,gaps:gaps)
                let bounds=try store.bounds()
                DispatchQueue.main.async {
                    guard self.historyRequest==request else {return}
                    self.historyFrames=frames;self.historySummaries=summaries;self.historyBounds=bounds
                    self.gaps=gaps;self.historyLoading=false
                }
            } catch {
                DispatchQueue.main.async {guard self.historyRequest==request else {return};self.historyLoading=false;self.historyError=error.localizedDescription}
            }
        }
    }
    init(previewFrames:[Frame]?=nil) {
        if let previewFrames {frames=previewFrames;liveFrame=previewFrames.last;return}
        let storedInterval=UserDefaults.standard.double(forKey:"recording.interval")
        if [2.0,5,10].contains(storedInterval) {interval=storedInterval}
        do {
            let dir=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Watt",isDirectory:true)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            backend.store=try HistoryStore(path:dir.appendingPathComponent("history.sqlite").path)
            let restored=try backend.restore(); frames=restored.0; gaps=restored.1;historyBounds=try backend.store?.bounds()
        } catch { self.error="History unavailable: \(error.localizedDescription)"; backend.initializationError=self.error }
        let center=NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName:NSWorkspace.willSleepNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.setSleeping(true) } })
        observers.append(center.addObserver(forName:NSWorkspace.didWakeNotification,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.setSleeping(false) } })
        scheduleSample(after:0)
    }
    private func scheduleSample(after delay:TimeInterval) {
        timer?.invalidate();timer=nil
        guard !paused,!sleeping,!collecting else {return}
        let timer=Timer(timeInterval:max(0.01,delay),repeats:false) { [weak self] _ in
            MainActor.assumeIsolated {self?.tick()}
        }
        timer.tolerance=min(1,max(0,delay)*0.1)
        self.timer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    private func tick() {
        guard !paused,!sleeping,!collecting else {return}
        collecting=true
        let began=ProcessInfo.processInfo.systemUptime,cadence=interval
        queue.async { [self] in
            let result=autoreleasepool { () -> (Frame?,String?,[RecordingGap],Int64) in
                let (frame,failure)=backend.sample(cadence:cadence)
                return (frame,failure,(try? backend.store?.gaps()) ?? [],backend.store?.diskBytes ?? 0)
            }
            DispatchQueue.main.async {
                self.collecting=false
                if let frame=result.0 {
                    self.frames=LiveFrameRetention.appending(frame,to:self.frames)
                    self.liveFrame=frame
                }
                if self.error != result.1 {self.error=result.1}
                let sameGaps=self.gaps.count==result.2.count && zip(self.gaps,result.2).allSatisfy {
                    $0.id==$1.id && $0.start==$1.start && $0.end==$1.end && $0.reason==$1.reason
                }
                if !sameGaps {self.gaps=result.2}
                if self.storageBytes != result.3 {self.storageBytes=result.3}
                let remaining=self.interval-(ProcessInfo.processInfo.systemUptime-began)
                self.scheduleSample(after:max(0,remaining))
            }
        }
    }
    func setPaused(_ value:Bool) {
        guard paused != value else {return};paused=value
        if value {queue.async {self.backend.interrupt(reason:"Recording paused")}}
        scheduleSample(after:0)
    }
    private func setSleeping(_ value:Bool) {
        sleeping=value
        queue.async {self.backend.interrupt(reason:"Device asleep")}
        scheduleSample(after:0)
    }
    var visibleGaps:[RecordingGap] {
        let range:DateInterval
        if let historyRange {range=historyRange}
        else if let first=frames.first?.time,let last=frames.last?.time {range=DateInterval(start:first,end:max(first,last))}
        else {return []}
        return gaps.compactMap { gap in
            let start=max(range.start,gap.start),end=min(range.end,gap.end ?? Date())
            guard start<end else {return nil}
            return RecordingGap(id:gap.id,start:start,end:end,reason:gap.reason)
        }
    }
    func selectionGap() -> RecordingGap? { selected.flatMap { time in gaps.first { $0.contains(time) } } }

}

func bytes(_ value:UInt64) -> String { ByteCountFormatter.string(fromByteCount:Int64(clamping:value),countStyle:.binary) }

func diskRate(_ value:UInt64?,elapsed:Double?) -> String {
    guard let value,let elapsed,elapsed>0 else {return "—"}
    return bytes(UInt64(Double(value)/elapsed)) + "/s"
}

// The SQLite recorder retains all samples; the live UI needs only a bounded recent working set.
enum LiveFrameRetention {
    static let maximumFrames=120
    static let maximumProcessRows=50_000
    static func appending(_ frame:Frame,to frames:[Frame])->[Frame] {
        var next=frames;next.append(frame)
        var rows=next.reduce(0) {$0+$1.processes.count},remove=0
        while next.count-remove>1 && (next.count-remove>maximumFrames || rows>maximumProcessRows) {
            rows-=next[remove].processes.count;remove+=1
        }
        if remove>0 {next.removeFirst(remove)}
        return next
    }
}
