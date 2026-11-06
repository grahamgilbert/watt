import XCTest
import CTelemetry

final class MemoryAccountingTests:XCTestCase {
    func testUsedMemoryExcludesReclaimableAnonymousPages() {
        // VM sample: anonymous 756070, purgeable 25530, wired 244938, compressed 530806.
        // File-backed pages (504561) must not inflate the used-memory total.
        let used=watt_memory_used_pages(756070,25530,244938,530806)*16384
        XCTAssertEqual(used,24678957056)
    }
    func testPurgeableCounterCannotUnderflowAppMemory() {
        XCTAssertEqual(watt_memory_used_pages(10,20,30,40),70)
    }
}
