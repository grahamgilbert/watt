import Foundation
import Combine
import AppKit
import CTelemetry
import WattEnergyProtocol

struct ProcessRow: Identifiable, Codable {
    var pid: Int32; var parent: Int32; var start: UInt64; var name: String
    var cpu: Double?; var memory: UInt64?; var growth: Int64?
    var read: UInt64?; var written: UInt64?
    // Deltas over the frame's measured interval. Energy is kernel-attributed CPU energy only.
    var energyNanojoules: UInt64? = nil
    var idleWakeups: UInt64? = nil
    var interruptWakeups: UInt64? = nil
    var applicationID: String? = nil
    var applicationName: String? = nil
    var userID: UInt32? = nil
    var metricSource: String? = nil
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
    // Independent passive network captures have their own identity and interval.
    var processNetwork:ProcessNetworkSample? = nil
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
    private var processSource:String?
    private var last: TimeInterval?
    private var lastSystem:TimeInterval?
    private let applicationResolver=ProcessApplicationResolver()
    private let processNetworkCollector=ProcessNetworkCollector()
    private var processNetworkEnabled=true
    private var baselineStartedAt=Date()
    private let privilegedSample:()->ProcessTelemetrySample?
    init(privilegedSample:@escaping ()->ProcessTelemetrySample? = {PrivilegedProcessClient.shared.sample()}) {
        self.privilegedSample=privilegedSample
    }
    func sample(cadence:Double=5) -> Frame? {
        failed = false
        var system = WattSystem()
        guard watt_system(&system) != 0 else { failed = true; return nil }
        let systemUptime=ProcessInfo.processInfo.systemUptime
        let systemElapsed=lastSystem.map {systemUptime-$0}
        let privileged=privilegedSample()
        var buffer:[WattProcess]
        let now:TimeInterval,sampledAt:Date,denied:Int,count:Int,source:String
        if let privileged {
            buffer=privileged.tasks.map(ProcessMeasurements.counters)
            now=privileged.uptime;sampledAt=privileged.sampledAt;denied=privileged.denied
            count=buffer.count;source="privileged"
        } else {
            buffer=[WattProcess](repeating:WattProcess(),count:16384)
            var unavailable:Int32=0
            count=Int(watt_processes(&buffer,Int32(buffer.count),&unavailable))
            now=ProcessInfo.processInfo.systemUptime;sampledAt=Date()
            denied=count<0 ? -1 : Int(unavailable);source="local"
        }
        let elapsed=last.map {now-$0}
        var next: [String: WattProcess] = [:]
        let rows = buffer.prefix(max(0,count)).map { p -> ProcessRow in
            let key = "\(p.pid):\(p.start)"; next[key] = p
            let old=processSource==source ? processes[key] : nil
            var row=ProcessMeasurements.row(current:p,previous:old,elapsed:elapsed,source:source)
            let application=applicationResolver.identity(for:p)
            row.applicationID=application?.id;row.applicationName=application?.name
            return row
        }
        applicationResolver.retain(processIDs:Set(next.keys))
        let network=processNetworkEnabled ? processNetworkCollector.sample(processes:rows,cadence:cadence) : nil
        var cpu = 0.0, rx = 0.0, tx = 0.0
        if let old=previous,let systemElapsed,systemElapsed>0 {
            let active = Double(delta(system.user, old.user) ?? 0) + Double(delta(system.system, old.system) ?? 0)
            let idle = Double(delta(system.idle, old.idle) ?? 0)
            cpu = active / max(1, active + idle) * 100
            rx=Double(delta(system.rx,old.rx) ?? 0)/systemElapsed;tx=Double(delta(system.tx,old.tx) ?? 0)/systemElapsed
        }
        let baseline = previous != nil
        previous=system;processes=next;processSource=source;last=now;lastSystem=systemUptime
        guard baseline else { return nil }
        let energyImpact=EnergyImpactCache.shared.latest(maxAge:15,now:sampledAt).flatMap { $0.startedAt>=baselineStartedAt ? $0 : nil }
        return Frame(time:sampledAt,cpu:cpu,memory:system.memory,compressed:system.compressed,swap:system.swap,
                     download:rx,upload:tx,processes:rows,denied:denied,power:PowerReading.read(),elapsed:elapsed,memoryAccounting:"app-wired-compressed",processCPUAccounting:"mach-timebase-to-nanoseconds",energyImpact:energyImpact,processNetwork:network)
    }
    func setProcessNetworkEnabled(_ value:Bool) {
        guard value != processNetworkEnabled else {return}
        processNetworkEnabled=value;processNetworkCollector.reset()
    }
    func stop() {processNetworkCollector.stop()}
    func reset() {previous=nil;processes=[:];processSource=nil;last=nil;lastSystem=nil;baselineStartedAt=Date();processNetworkCollector.reset()}
}

@MainActor final class Monitor: ObservableObject {
    @Published var frames:[Frame]=[] {didSet{invalidateCurrentSnapshot()}}
    @Published var liveFrame:Frame?
    @Published var historyFrames:[Frame]=[] {didSet{invalidateCurrentSnapshot()}}
    @Published var historyRange:DateInterval? {didSet{invalidateCurrentSnapshot()}}
    @Published var historyBounds:DateInterval?
    @Published var historySummaries:[ProcessSummary]=[]
    @Published var historyLoading=false
    @Published var historyError:String?
    private var historyRequest=UUID()
    private var historyWork:PopupHistoryRequest?
    private var isPreview=false
    let explorerLiveHistory=ExplorerLiveHistory()
    var visibleFrames:[Frame] {historyRange == nil ? (explorerLiveHistory.isVisible ? explorerLiveHistory.frames : frames) : historyFrames}
    @Published var paused=false
    @Published var error:String?
    @Published var interval=5.0 {didSet {UserDefaults.standard.set(interval,forKey:"recording.interval");scheduleSample(after:0)}}
    @Published var recordsProcessNetwork=true {didSet {
        UserDefaults.standard.set(recordsProcessNetwork,forKey:"recording.processNetwork.enabled")
        let enabled=recordsProcessNetwork
        queue.async {self.backend.collector.setProcessNetworkEnabled(enabled)}
    }}
    @Published var selected:Date? {didSet{invalidateCurrentSnapshot()}}
    @Published var gaps:[RecordingGap]=[] {didSet{invalidateCurrentSnapshot()}}
    @Published var storageBytes:Int64=0
    private var sleeping=false
    private var observers:[NSObjectProtocol]=[]
    private let queue=DispatchQueue(label:"app.watt.recorder",qos:.utility)
    private var timer:Timer?
    private var collecting=false
    private var shuttingDown=false
    private nonisolated let backend=RecorderBackend()
    private var cachedCurrentSnapshot:Frame?
    private var currentSnapshotResolved=false
    private(set) var snapshotLookupCount=0
    private func invalidateCurrentSnapshot() {
        cachedCurrentSnapshot=nil;currentSnapshotResolved=false
    }
    var current:Frame? {
        guard let selected else {return historyRange == nil ? liveFrame : nil}
        // A table asks for the selected snapshot from many cells and helpers.
        // Resolve it once per data/selection change, including unavailable results.
        if !currentSnapshotResolved {
            cachedCurrentSnapshot=HistoryAnalysis.snapshot(at:selected,frames:visibleFrames,gaps:gaps)
            currentSnapshotResolved=true;snapshotLookupCount+=1
        }
        return cachedCurrentSnapshot
    }
    func returnToLive() {historyWork?.cancel();historyWork=nil;historyRequest=UUID();historyRange=nil;historyFrames=[];historySummaries=[];selected=nil;historyLoading=false;historyError=nil}
    func releaseHistoryDetails() {
        explorerLiveHistory.hide()
        historyWork?.cancel();historyWork=nil
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
        explorerLiveHistory.hide()
        historyWork?.cancel()
        let work=PopupHistoryRequest();historyWork=work
        let request=UUID();historyRequest=request;historyRange=range;selected=center
        historyFrames=[];historySummaries=[];historyLoading=true;historyError=nil
        queue.async { [self] in
            guard !work.isCancelled else {return}
            do {
                guard let store=backend.store else {throw NSError(domain:"Watt",code:1,userInfo:[NSLocalizedDescriptionKey:"History database is unavailable"])}
                let frames=try store.frames(in:range,isCancelled:{work.isCancelled})
                guard !work.isCancelled else {return}
                let gaps=try store.gaps()
                let summaries=HistoryAnalysis.summarize(frames,range:range,gaps:gaps)
                guard !work.isCancelled else {return}
                let bounds=try store.bounds()
                DispatchQueue.main.async {
                    guard !work.isCancelled,self.historyRequest==request else {return}
                    self.historyWork=nil
                    self.historyFrames=frames;self.historySummaries=summaries;self.historyBounds=bounds
                    self.gaps=gaps;self.historyLoading=false
                }
            } catch {
                DispatchQueue.main.async {guard !work.isCancelled,self.historyRequest==request else {return};self.historyWork=nil;self.historyLoading=false;self.historyError=error.localizedDescription}
            }
        }
    }
    func prepareExplorerLiveHistory(duration:Double) {
        guard !isPreview,historyRange==nil else {return}
        explorerLiveHistory.show(duration:duration,liveFrames:frames,gaps:gaps) { [weak self] range,work,completion in
            guard let self else {return}
            self.queue.async { [self] in
                // Closing Explorer can cancel this request while it waits behind
                // a recorder write. Do not start decoding after it is hidden.
                guard !work.isCancelled else {return}
                let result:Result<(snapshot:PopupHistorySnapshot,bounds:DateInterval?),Error>=Result {
                    guard let store=self.backend.store else {throw NSError(domain:"Watt",code:1,userInfo:[NSLocalizedDescriptionKey:"History database is unavailable"])}
                    let frames=try store.frames(in:range,maximumFrames:ExplorerLiveHistory.maximumFrames,
                                               maximumBytes:ExplorerLiveHistory.maximumBytes,isCancelled:{work.isCancelled})
                    guard ExplorerLiveHistory.fits(frames) else {throw HistoryQueryError.tooBroad}
                    return (PopupHistorySnapshot(frames:frames,gaps:try store.gaps()),try store.bounds())
                }
                guard !work.isCancelled else {return}
                DispatchQueue.main.async {
                    guard !work.isCancelled else {return}
                    switch result {
                    case .success(let loaded):self.historyBounds=loaded.bounds;completion(.success(loaded.snapshot))
                    case .failure(let error):completion(.failure(error))
                    }
                }
            }
        }
    }
    func pinExplorer(at time:Date,in range:DateInterval) {
        guard historyRange==nil else {selected=time;return}
        let cached=explorerLiveHistory.frames
        let cachedGaps=explorerLiveHistory.gaps
        let complete=explorerLiveHistory.isComplete
        if !complete {
            loadHistory(center:range.start.addingTimeInterval(range.duration/2),duration:range.duration)
            selected=time
            return
        }
        // The visible window is already complete. Pin it without reading SQLite
        // again, and calculate its interval summary once off the main thread.
        historyWork?.cancel();let work=PopupHistoryRequest();historyWork=work
        let request=UUID();historyRequest=request
        historyRange=range;historyFrames=cached;gaps=cachedGaps;selected=time
        historySummaries=[];historyLoading=true;historyError=nil
        explorerLiveHistory.hide();invalidateCurrentSnapshot()
        queue.async { [self] in
            guard !work.isCancelled else {return}
            let summaries=HistoryAnalysis.summarize(cached,range:range,gaps:cachedGaps)
            guard !work.isCancelled else {return}
            DispatchQueue.main.async {
                guard !work.isCancelled,self.historyRequest==request else {return}
                self.historyWork=nil;self.historySummaries=summaries;self.historyLoading=false
            }
        }
    }
    // Detail popovers have an independent cursor and a smaller query budget.
    // Use the same serial database queue without changing Explorer's history.
    func loadPopupHistory(in range:DateInterval,request:PopupHistoryRequest,completion:@escaping(Result<PopupHistorySnapshot,Error>)->Void) {
        queue.async { [self] in
            guard !request.isCancelled else {return}
            let result:Result<PopupHistorySnapshot,Error>=Result {
                guard let store=backend.store else {throw NSError(domain:"Watt",code:1,userInfo:[NSLocalizedDescriptionKey:"Earlier history is unavailable."])}
                let frames=try store.frames(in:range,maximumFrames:PopupDetailSession.maximumFrames,maximumBytes:32*1024*1024,isCancelled:{request.isCancelled})
                guard frames.reduce(0,{$0+PopupDetailSession.rowCost($1)})<=PopupDetailSession.maximumProcessRows else {throw HistoryQueryError.tooBroad}
                return PopupHistorySnapshot(frames:frames,gaps:try store.gaps())
            }
            guard !request.isCancelled else {return}
            DispatchQueue.main.async {if !request.isCancelled {completion(result)}}
        }
    }
    init(previewFrames:[Frame]?=nil) {
        if let previewFrames {isPreview=true;frames=previewFrames;liveFrame=previewFrames.last;return}
        if UserDefaults.standard.object(forKey:"recording.processNetwork.enabled") != nil {
            recordsProcessNetwork=UserDefaults.standard.bool(forKey:"recording.processNetwork.enabled")
        }
        backend.collector.setProcessNetworkEnabled(recordsProcessNetwork)
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
        guard !paused,!sleeping,!collecting,!shuttingDown else {return}
        let timer=Timer(timeInterval:max(0.01,delay),repeats:false) { [weak self] _ in
            MainActor.assumeIsolated {self?.tick()}
        }
        timer.tolerance=min(1,max(0,delay)*0.1)
        self.timer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    private func tick() {
        guard !paused,!sleeping,!collecting,!shuttingDown else {return}
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
    func stopRecording() {
        shuttingDown=true;timer?.invalidate();timer=nil
        queue.sync {backend.collector.stop()}
    }
    private func setSleeping(_ value:Bool) {
        sleeping=value
        queue.async {self.backend.interrupt(reason:"Device asleep")}
        scheduleSample(after:0)
    }
    var visibleGaps:[RecordingGap] {
        let range:DateInterval
        if let historyRange {range=historyRange}
        else if explorerLiveHistory.isVisible,let liveRange=explorerLiveHistory.range {range=liveRange}
        else if let first=frames.first?.time,let last=frames.last?.time {range=DateInterval(start:first,end:max(first,last))}
        else {return []}
        let values=historyRange==nil && explorerLiveHistory.isVisible ? explorerLiveHistory.gaps : gaps
        return values.compactMap { gap in
            let start=max(range.start,gap.start),end=min(range.end,gap.end ?? Date())
            guard start<end else {return nil}
            return RecordingGap(id:gap.id,start:start,end:end,reason:gap.reason)
        }
    }
    func selectionGap() -> RecordingGap? { selected.flatMap { time in gaps.first { $0.contains(time) } } }

}

// Table cells format footprint and disk values repeatedly. Reuse the formatter
// instead of rebuilding its localization state for every value. Serialize access
// because diagnostics and UI callers can run on different queues.
private final class BinaryByteFormatter:@unchecked Sendable {
    static let shared=BinaryByteFormatter()
    private let lock=NSLock()
    private let formatter:ByteCountFormatter
    private init() {
        formatter=ByteCountFormatter();formatter.countStyle = .binary
    }
    func string(_ value:UInt64)->String {
        lock.lock();defer {lock.unlock()}
        return formatter.string(fromByteCount:Int64(clamping:value))
    }
}
func bytes(_ value:UInt64) -> String {BinaryByteFormatter.shared.string(value)}

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
