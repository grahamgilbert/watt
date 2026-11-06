import Foundation
import XCTest
@testable import Watt

final class MonitorSnapshotCacheTests:XCTestCase {
    private let origin=Date(timeIntervalSince1970:1_800_000_000)
    private func frame(_ second:Double,cpu:Double=10)->Frame {
        Frame(time:origin.addingTimeInterval(second),cpu:cpu,memory:100,compressed:0,swap:0,
              download:0,upload:0,processes:[],denied:0,elapsed:5,cadence:5)
    }

    @MainActor func testRepeatedReadsResolveTheSelectedSnapshotOnce() async {
        let frames=(1...120).map {frame(Double($0)*5)}
        let monitor=Monitor(previewFrames:frames)
        monitor.selected=frames[60].time
        for _ in 0..<800 {XCTAssertEqual(monitor.current?.time,frames[60].time)}
        XCTAssertEqual(monitor.snapshotLookupCount,1)
    }

    @MainActor func testReplacingLiveFramesInvalidatesEvenWhenTimestampsMatch() async {
        let monitor=Monitor(previewFrames:[frame(5,cpu:10)])
        monitor.selected=origin.addingTimeInterval(5)
        XCTAssertEqual(monitor.current?.cpu,10)
        monitor.frames=[frame(5,cpu:80)]
        XCTAssertEqual(monitor.current?.cpu,80)
        XCTAssertEqual(monitor.snapshotLookupCount,2)
    }

    @MainActor func testReplacingHistoricalFramesRefreshesTheSelectedSnapshot() async {
        let monitor=Monitor(previewFrames:[frame(5,cpu:10)])
        monitor.historyRange=DateInterval(start:origin,duration:20)
        monitor.historyFrames=[frame(5,cpu:20)]
        monitor.selected=origin.addingTimeInterval(5)
        XCTAssertEqual(monitor.current?.cpu,20)
        monitor.historyFrames=[frame(5,cpu:70)]
        XCTAssertEqual(monitor.current?.cpu,70)
        XCTAssertEqual(monitor.snapshotLookupCount,2)
    }

    @MainActor func testSwitchingBetweenLiveAndHistoricalSourcesCannotReuseTheOtherSnapshot() async {
        let monitor=Monitor(previewFrames:[frame(5,cpu:10)])
        monitor.historyFrames=[frame(5,cpu:90)]
        monitor.selected=origin.addingTimeInterval(5)
        XCTAssertEqual(monitor.current?.cpu,10)
        monitor.historyRange=DateInterval(start:origin,duration:20)
        XCTAssertEqual(monitor.current?.cpu,90)
        monitor.historyRange=nil
        XCTAssertEqual(monitor.current?.cpu,10)
        XCTAssertEqual(monitor.snapshotLookupCount,3)
    }

    @MainActor func testMovingTheCursorResolvesTheNewSelection() async {
        let monitor=Monitor(previewFrames:[frame(5,cpu:10),frame(10,cpu:90)])
        monitor.selected=origin.addingTimeInterval(5)
        XCTAssertEqual(monitor.current?.cpu,10)
        monitor.selected=origin.addingTimeInterval(10)
        XCTAssertEqual(monitor.current?.cpu,90)
        XCTAssertEqual(monitor.snapshotLookupCount,2)
    }

    @MainActor func testRecordingGapsInvalidateCachedReadingsAndUnavailableResultsAreCached() async {
        let monitor=Monitor(previewFrames:[frame(5)])
        monitor.selected=origin.addingTimeInterval(5)
        XCTAssertNotNil(monitor.current)
        monitor.gaps=[RecordingGap(id:"gap",start:origin.addingTimeInterval(4),
                                  end:origin.addingTimeInterval(6),reason:"Device asleep")]
        XCTAssertNil(monitor.current)
        XCTAssertNil(monitor.current)
        XCTAssertEqual(monitor.snapshotLookupCount,2)
        monitor.gaps=[]
        XCTAssertNotNil(monitor.current)
        XCTAssertEqual(monitor.snapshotLookupCount,3)
    }

    @MainActor func testMissingCoverageIsReconsideredWhenNewFramesArrive() async {
        let monitor=Monitor(previewFrames:[frame(5)])
        monitor.selected=origin.addingTimeInterval(1000)
        XCTAssertNil(monitor.current)
        XCTAssertNil(monitor.current)
        XCTAssertEqual(monitor.snapshotLookupCount,1)
        monitor.frames.append(frame(1000))
        XCTAssertEqual(monitor.current?.time,origin.addingTimeInterval(1000))
        XCTAssertEqual(monitor.snapshotLookupCount,2)
    }

    @MainActor func testClearingHistoricalDetailsReleasesTheCachedSelection() async {
        let monitor=Monitor(previewFrames:[frame(5,cpu:10)])
        monitor.historyRange=DateInterval(start:origin,duration:20)
        monitor.historyFrames=[frame(5,cpu:90)]
        monitor.selected=origin.addingTimeInterval(5)
        XCTAssertEqual(monitor.current?.cpu,90)
        monitor.historyFrames=[]
        XCTAssertNil(monitor.current)
        XCTAssertEqual(monitor.snapshotLookupCount,2)
    }

    @MainActor func testUnselectedLiveReadingsContinueUpdatingWithoutHistoryLookups() async {
        let monitor=Monitor(previewFrames:[frame(5,cpu:10)])
        XCTAssertEqual(monitor.current?.cpu,10)
        monitor.liveFrame=frame(10,cpu:80)
        XCTAssertEqual(monitor.current?.cpu,80)
        XCTAssertEqual(monitor.snapshotLookupCount,0)
        monitor.historyRange=DateInterval(start:origin,duration:20)
        XCTAssertNil(monitor.current)
    }
}
