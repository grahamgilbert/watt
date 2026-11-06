import XCTest
@testable import Watt

final class UpdateChannelTests:XCTestCase {
    func testStableAndPrereleaseFeedsBelongToWatt() {
        XCTAssertEqual(UpdateChannel.feedURL(includePrereleases:false).absoluteString,"https://raw.githubusercontent.com/grahamgilbert/watt/main/appcast.xml")
        XCTAssertEqual(UpdateChannel.feedURL(includePrereleases:true).absoluteString,"https://raw.githubusercontent.com/grahamgilbert/watt/main/appcast-prerelease.xml")
    }
}
