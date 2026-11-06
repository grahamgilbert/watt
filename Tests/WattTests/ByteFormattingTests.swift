import Foundation
import XCTest
@testable import Watt

final class ByteFormattingTests:XCTestCase {
    private let values:[UInt64]=[0,1,512,1023,1024,1025,1_048_575,1_048_576,1_073_741_824,
                                1_099_511_627_776,UInt64(Int64.max),UInt64.max]
    func testReusedFormatterPreservesBinaryUnitsAndClamping() {
        for value in values {
            XCTAssertEqual(bytes(value),ByteCountFormatter.string(fromByteCount:Int64(clamping:value),countStyle:.binary))
        }
    }

    func testConcurrentFormattingKeepsEachValueIndependent() {
        let values=self.values
        let expected=values.map {ByteCountFormatter.string(fromByteCount:Int64(clamping:$0),countStyle:.binary)}
        let results=FormattingResults()
        DispatchQueue.concurrentPerform(iterations:240) {index in
            let offset=index%values.count
            results.record(bytes(values[offset])==expected[offset])
        }
        XCTAssertEqual(results.failures,0)
    }
}

private final class FormattingResults:@unchecked Sendable {
    private let lock=NSLock()
    private var count=0
    func record(_ matches:Bool) {
        lock.lock();defer {lock.unlock()}
        if !matches {count+=1}
    }
    var failures:Int {
        lock.lock();defer {lock.unlock()}
        return count
    }
}
