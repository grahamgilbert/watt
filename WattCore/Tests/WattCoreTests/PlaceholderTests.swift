import XCTest
@testable import WattModels

final class PlaceholderTests: XCTestCase {
    func testStoreSchemaListsAllModels() {
        let names = WattStore.schema.entities.map(\.name).sorted()
        XCTAssertEqual(
            names,
            ["DrainEpisode", "ProcessSample", "Report", "Sample", "UserEvent"]
        )
    }
}
