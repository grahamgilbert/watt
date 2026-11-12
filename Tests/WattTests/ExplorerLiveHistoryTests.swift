import XCTest
import WattEnergyProtocol
@testable import Watt

final class ExplorerLiveHistoryTests:XCTestCase {
    private let origin=Date(timeIntervalSince1970:1_800_000_000)
    private func frame(_ second:Double,rows:Int=1,cpu:Double=10)->Frame {
        let process=ProcessRow(pid:1,parent:0,start:1,name:"fixture",cpu:cpu,memory:1024,growth:nil,read:10,written:20)
        return Frame(time:origin.addingTimeInterval(second),cpu:cpu,memory:1024,compressed:0,swap:0,
                     download:1,upload:2,processes:Array(repeating:process,count:rows),denied:0,
                     segment:"recorded",elapsed:5,cadence:5)
    }

    @MainActor func testFullQuarterHourBackfillsBeyondTheBoundedRecorderCacheAndFollowsWithoutReads() throws {
        let saved=(0...180).map {frame(Double($0)*5,rows:1000)}
        let cache=saved.reduce(into:[Frame]()) {$0=LiveFrameRetention.appending($1,to:$0)}
        XCTAssertEqual(cache.count,50,"The background recorder keeps its existing small inventory")
        let session=ExplorerLiveHistory()
        var loads=0
        session.show(duration:900,liveFrames:cache,gaps:[]) {range,_,finish in
            loads+=1
            XCTAssertEqual(range.start,self.origin)
            finish(.success(PopupHistorySnapshot(frames:saved,gaps:[])))
        }
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.frames.count,181)
        XCTAssertEqual(session.frames.first?.time,origin)
        for second in stride(from:905.0,through:1000.0,by:5) {session.observe(frame(second,rows:1000),gaps:[])}
        XCTAssertEqual(loads,1,"Live arrivals extend the loaded interval without another SQLite query")
        XCTAssertEqual(session.frames.count,181)
        XCTAssertEqual(session.frames.first?.time,origin.addingTimeInterval(100))
        XCTAssertEqual(session.frames.last?.time,origin.addingTimeInterval(1000))
        XCTAssertTrue(session.isComplete)
    }

    @MainActor func testPendingBackfillMergesNewArrivalsByTimeWithoutReplacingNewerReadings() throws {
        let session=ExplorerLiveHistory()
        var finish:((Result<PopupHistorySnapshot,Error>)->Void)?
        session.show(duration:900,liveFrames:[frame(900,cpu:80)],gaps:[]) {_,_,done in finish=done}
        session.observe(frame(905,cpu:90),gaps:[])
        finish?(.success(PopupHistorySnapshot(frames:[frame(5),frame(900,cpu:1)],gaps:[])))
        XCTAssertEqual(session.frames.map(\.time),[5.0,900,905].map {origin.addingTimeInterval($0)})
        XCTAssertEqual(session.frames.first(where:{$0.time==origin.addingTimeInterval(900)})?.cpu,80)
        XCTAssertEqual(session.frames.last?.cpu,90)
        XCTAssertTrue(session.isComplete)
    }

    @MainActor func testQuarterHourIncludesProcessEnergyAndNetworkInventoriesAtObservedDeviceScale() {
        let energy=(0..<122).map {EnergyImpactTask(pid:Int32($0+1),name:"fixture",energyImpact:0,energyImpactPerSecond:0)}
        let network=(0..<80).map {ProcessNetworkTask(pid:Int32($0+1),parent:1,start:1,name:"fixture",receivedBytes:0,sentBytes:0)}
        let saved=(0...180).map {index in
            var value=frame(Double(index)*5,rows:1044)
            let began=value.time.addingTimeInterval(-5)
            value.energyImpact=EnergyImpactSample(id:"energy-\(index)",startedAt:began,endedAt:value.time,tasks:energy)
            value.processNetwork=ProcessNetworkSample(id:"network-\(index)",startedAt:began,endedAt:value.time,elapsed:5,tasks:network,status:.available,source:"fixture",unmatchedProcesses:0)
            return value
        }
        let session=ExplorerLiveHistory()
        session.show(duration:900,liveFrames:Array(saved.suffix(36)),gaps:[]) {_,_,finish in
            finish(.success(PopupHistorySnapshot(frames:saved,gaps:[])))
        }
        XCTAssertTrue(session.isComplete)
        XCTAssertNil(session.error)
        XCTAssertEqual(session.frames.count,181)
        XCTAssertEqual(session.frames.first?.time,origin)
        XCTAssertEqual(session.frames.first?.energyImpact?.tasks.count,122)
        XCTAssertEqual(session.frames.first?.processNetwork?.tasks.count,80)
    }

    @MainActor func testHidingCancelsQueuedWorkRejectsLateResultsAndReopeningReloads() throws {
        let session=ExplorerLiveHistory()
        var finish:((Result<PopupHistorySnapshot,Error>)->Void)?
        var request:PopupHistoryRequest?
        session.show(duration:900,liveFrames:[frame(900)],gaps:[]) {_,work,done in request=work;finish=done}
        session.hide()
        XCTAssertTrue(try XCTUnwrap(request).isCancelled)
        session.observe(frame(905),gaps:[])
        finish?(.success(PopupHistorySnapshot(frames:[frame(0),frame(900)],gaps:[])))
        XCTAssertTrue(session.frames.isEmpty)
        XCTAssertNil(session.range)
        XCTAssertFalse(session.isLoading)
        XCTAssertFalse(session.isVisible)
        var loads=0
        session.show(duration:900,liveFrames:[frame(905)],gaps:[]) {_,_,done in
            loads+=1;done(.success(PopupHistorySnapshot(frames:[self.frame(5),self.frame(905)],gaps:[])))
        }
        XCTAssertEqual(loads,1)
        XCTAssertEqual(session.frames.first?.time,origin.addingTimeInterval(5))
    }

    @MainActor func testExpandingCancelsAnOlderRangeAndShrinkingCompleteCoverageNeedsNoRead() throws {
        let session=ExplorerLiveHistory()
        var completions:[(Result<PopupHistorySnapshot,Error>)->Void]=[]
        var requests:[PopupHistoryRequest]=[]
        let loader:ExplorerLiveHistory.Loader={_,work,finish in requests.append(work);completions.append(finish)}
        session.show(duration:60,liveFrames:[frame(900)],gaps:[],loader:loader)
        session.show(duration:900,liveFrames:[frame(900)],gaps:[],loader:loader)
        XCTAssertEqual(requests.count,2)
        XCTAssertTrue(requests[0].isCancelled)
        completions[0](.success(PopupHistorySnapshot(frames:[frame(840),frame(900)],gaps:[])))
        XCTAssertTrue(session.isLoading)
        completions[1](.success(PopupHistorySnapshot(frames:[frame(0),frame(840),frame(900)],gaps:[])))
        XCTAssertEqual(session.frames.first?.time,origin)
        session.show(duration:60,liveFrames:[frame(900)],gaps:[],loader:loader)
        XCTAssertEqual(requests.count,2)
        XCTAssertEqual(session.frames.first?.time,origin.addingTimeInterval(840))
        session.show(duration:900,liveFrames:[frame(900)],gaps:[],loader:loader)
        XCTAssertEqual(requests.count,3,"An expanded prefix was released and must be loaded again")
    }

    @MainActor func testBudgetFailureIsExplicitAndNeverTurnsIntoASilentTrailingSuffix() throws {
        let session=ExplorerLiveHistory()
        var loads=0
        let loader:ExplorerLiveHistory.Loader={_,_,finish in
            loads+=1
            if loads==1 {finish(.failure(HistoryQueryError.tooBroad))}
            else {finish(.success(PopupHistorySnapshot(frames:[self.frame(840),self.frame(900)],gaps:[])))}
        }
        session.show(duration:3600,liveFrames:[frame(900)],gaps:[],loader:loader)
        XCTAssertNotNil(session.error)
        XCTAssertTrue(session.frames.isEmpty)
        XCTAssertFalse(session.isComplete)
        session.observe(frame(905),gaps:[])
        XCTAssertTrue(session.frames.isEmpty)
        XCTAssertEqual(loads,1)
        session.show(duration:60,liveFrames:[frame(900)],gaps:[],loader:loader)
        XCTAssertNil(session.error)
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(loads,2)
        XCTAssertFalse(ExplorerLiveHistory.fits([frame(900,rows:ExplorerLiveHistory.maximumRows+1)]))
        XCTAssertFalse(ExplorerLiveHistory.fits((0...ExplorerLiveHistory.maximumFrames).map {frame(Double($0))}))
    }

    @MainActor func testBackfilledGapsSurviveNewArrivalsAndClipAgainstTheFullVisibleRange() throws {
        let session=ExplorerLiveHistory()
        let gap=RecordingGap(id:"sleep",start:origin.addingTimeInterval(100),end:origin.addingTimeInterval(200),reason:"Device asleep")
        let cache=[frame(850),frame(900)]
        let monitor=Monitor(previewFrames:cache)
        monitor.explorerLiveHistory.show(duration:900,liveFrames:cache,gaps:[]) {_,_,finish in
            finish(.success(PopupHistorySnapshot(frames:[self.frame(0)]+cache,gaps:[gap])))
        }
        XCTAssertEqual(monitor.visibleGaps.map(\.id),["sleep"],"Gaps before the short recorder cache remain visible")
        session.show(duration:900,liveFrames:cache,gaps:[]) {_,_,finish in
            finish(.success(PopupHistorySnapshot(frames:[self.frame(0)]+cache,gaps:[gap])))
        }
        session.observe(frame(905),gaps:[])
        XCTAssertEqual(session.gaps.map(\.id),["sleep"])
        session.observe(frame(1105),gaps:[])
        XCTAssertTrue(session.gaps.isEmpty,"Expired gaps leave the moving window")
    }

    @MainActor func testPinningAdoptsTheCompleteWindowAndDoesNotFollowFutureSamples() throws {
        let cache=[frame(850),frame(900)]
        let monitor=Monitor(previewFrames:cache)
        monitor.explorerLiveHistory.show(duration:900,liveFrames:cache,gaps:[]) {_,_,finish in
            finish(.success(PopupHistorySnapshot(frames:[self.frame(0),self.frame(300)]+cache,gaps:[])))
        }
        let range=try XCTUnwrap(monitor.explorerLiveHistory.range)
        let pinned=origin.addingTimeInterval(300)
        monitor.pinExplorer(at:pinned,in:range)
        XCTAssertEqual(monitor.selected,pinned)
        XCTAssertEqual(monitor.historyRange,range)
        XCTAssertEqual(monitor.current?.time,pinned)
        XCTAssertEqual(monitor.historyFrames.first?.time,origin)
        XCTAssertFalse(monitor.explorerLiveHistory.isVisible)
        monitor.liveFrame=frame(905)
        monitor.explorerLiveHistory.observe(frame(905),gaps:[])
        XCTAssertEqual(monitor.historyRange,range)
        XCTAssertEqual(monitor.current?.time,pinned)
        monitor.releaseHistoryDetails()
    }

    @MainActor func testDateNavigationFollowsTheDisplayedWindowUnlessTheUserHasAnExplicitDraft() throws {
        let controls=ProcessExplorerControls()
        controls.center=origin.addingTimeInterval(-3600)
        let first=DateInterval(start:origin,duration:900)
        let later=DateInterval(start:origin.addingTimeInterval(300),duration:900)
        XCTAssertEqual(controls.navigationCenter(liveRange:first),origin.addingTimeInterval(450))
        XCTAssertEqual(controls.navigationCenter(liveRange:later),origin.addingTimeInterval(750))
        let draft=origin.addingTimeInterval(-1800)
        controls.editDate(draft)
        XCTAssertEqual(controls.navigationCenter(liveRange:later),draft)
        controls.inspectDate(draft)
        XCTAssertEqual(controls.navigationCenter(liveRange:nil),draft)
        controls.followLiveDate()
        XCTAssertEqual(controls.navigationCenter(liveRange:later),origin.addingTimeInterval(750))
        let longer=DateInterval(start:origin.addingTimeInterval(-600),duration:1800)
        XCTAssertEqual(controls.navigationCenter(liveRange:longer),origin.addingTimeInterval(300))
    }

    @MainActor func testPreviewAndBenchmarkFixturesKeepTheirFrameSourceWithoutARecordingDatabase() {
        let fixture=[frame(0),frame(300),frame(900)]
        let monitor=Monitor(previewFrames:fixture)
        monitor.prepareExplorerLiveHistory(duration:900)
        XCTAssertFalse(monitor.explorerLiveHistory.isVisible)
        XCTAssertEqual(monitor.visibleFrames.map(\.time),fixture.map(\.time))
        XCTAssertNil(monitor.explorerLiveHistory.error)
    }
}
