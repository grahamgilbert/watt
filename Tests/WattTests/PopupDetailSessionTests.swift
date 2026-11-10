import XCTest
@testable import Watt

final class PopupDetailSessionTests:XCTestCase {
    @MainActor func testOpeningCachedMinuteDoesNotReadDatabaseOrMoveExplorerCursor() throws {
        let monitor=Monitor(previewFrames:PopupLayoutPreview.frames)
        let cursor=try XCTUnwrap(monitor.frames.first?.time)
        monitor.selected=cursor
        let session=PopupDetailSession()
        var loads=0
        session.open(.cpu,liveFrames:monitor.frames,gaps:[]) {_,_,_ in loads+=1}
        XCTAssertEqual(loads,0)
        XCTAssertEqual(session.item,.cpu)
        XCTAssertNil(session.selectedTime)
        XCTAssertEqual(monitor.selected,cursor)
        XCTAssertFalse(session.frames.isEmpty)
    }

    @MainActor func testDismissalCancelsLateHistoryAndReopeningStartsAtNow() throws {
        let frame=try XCTUnwrap(PopupLayoutPreview.frames.last)
        let session=PopupDetailSession()
        var finish:((Result<PopupHistorySnapshot,Error>)->Void)?
        var work:PopupHistoryRequest?
        session.open(.cpu,liveFrames:[frame],gaps:[]) {_,request,completion in work=request;finish=completion}
        XCTAssertTrue(session.isLoading)
        session.reset()
        XCTAssertTrue(try XCTUnwrap(work).isCancelled,"Closing a detail cancels queued database work, not just its callback")
        finish?(.success(PopupHistorySnapshot(frames:PopupLayoutPreview.frames,gaps:[])))
        XCTAssertNil(session.item)
        XCTAssertTrue(session.frames.isEmpty)
        XCTAssertFalse(session.isLoading)
        session.open(.memory,liveFrames:PopupLayoutPreview.frames,gaps:[]) {_,_,_ in XCTFail("Recent minute was already cached")}
        XCTAssertEqual(session.item,.memory)
        XCTAssertNil(session.selectedTime)
        XCTAssertEqual(session.duration,60)
    }

    @MainActor func testPinnedDetailStaysAtSameWindowWhileRecordingContinues() throws {
        let initial=PopupLayoutPreview.frames
        var next=try XCTUnwrap(initial.last)
        let session=PopupDetailSession()
        session.open(.cpu,liveFrames:initial,gaps:[]) {_,_,_ in}
        let pinned=try XCTUnwrap(session.frames.first?.time)
        let oldEnd=try XCTUnwrap(session.frames.last?.time)
        session.select(pinned,liveFrames:initial,gaps:[])
        next.time=oldEnd.addingTimeInterval(5)
        session.observe(next,gaps:[])
        XCTAssertEqual(session.selectedTime,pinned)
        XCTAssertEqual(session.frames.last?.time,oldEnd)
        session.select(nil,liveFrames:initial+[next],gaps:[])
        XCTAssertNil(session.selectedTime)
        XCTAssertEqual(session.frames.last?.time,next.time)
    }

    @MainActor func testNewerRangeRejectsAnOlderQueryResult() throws {
        let frame=try XCTUnwrap(PopupLayoutPreview.frames.last)
        let session=PopupDetailSession()
        var completions:[(Result<PopupHistorySnapshot,Error>)->Void]=[]
        session.open(.memory,liveFrames:[frame],gaps:[]) {_,_,done in completions.append(done)}
        session.changeDuration(300,liveFrames:[frame],gaps:[])
        XCTAssertEqual(completions.count,2)
        completions[0](.success(PopupHistorySnapshot(frames:[],gaps:[])))
        XCTAssertTrue(session.isLoading)
        XCTAssertEqual(session.duration,300)
        completions[1](.success(PopupHistorySnapshot(frames:PopupLayoutPreview.frames,gaps:[])))
        XCTAssertFalse(session.isLoading)
        XCTAssertEqual(session.frames.last?.time,frame.time)
        session.reset()
        XCTAssertTrue(session.frames.isEmpty)
        XCTAssertEqual(session.duration,60)
    }
}
