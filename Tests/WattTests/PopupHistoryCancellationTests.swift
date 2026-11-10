import XCTest
@testable import Watt

final class PopupHistoryCancellationTests:XCTestCase {
    func testCancelledHistoryReadStopsInsideFrameDecodeLoop() throws {
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent("watt-popup-query-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:dir)}
        let store=try HistoryStore(path:dir.appendingPathComponent("history.sqlite").path)
        let frames=PopupLayoutPreview.frames
        let now=try XCTUnwrap(frames.last?.time)
        for frame in frames {try store.append(frame,now:now)}
        var checks=0
        let range=DateInterval(start:try XCTUnwrap(frames.first?.time),end:now)
        XCTAssertThrowsError(try store.frames(in:range,isCancelled:{checks+=1;return checks>=4})) {error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checks,4)
        XCTAssertEqual(try store.frames(in:range).count,frames.count,"Cancelling a read must not change recorded samples")
    }
}
