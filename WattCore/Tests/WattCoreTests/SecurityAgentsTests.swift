import XCTest
@testable import WattAnalysis

final class SecurityAgentsTests: XCTestCase {
    func testFalconCtlMatchesByName() {
        let def = SecurityAgents.match(name: "falconctl", bundleID: nil)
        XCTAssertEqual(def?.displayName, "CrowdStrike Falcon")
    }

    func testCyberhavenMatchesByBundleIDPrefix() {
        let def = SecurityAgents.match(name: "anything", bundleID: "com.cyberhaven.someHelper")
        XCTAssertEqual(def?.displayName, "Cyberhaven")
    }

    func testZscalerHelperMatches() {
        XCTAssertNotNil(SecurityAgents.match(name: "zsservice", bundleID: nil))
    }

    func testRandomProcessDoesNotMatch() {
        XCTAssertNil(SecurityAgents.match(name: "Xcode", bundleID: "com.apple.dt.Xcode"))
    }

    func testClassificationFallsBackToSystemRegistry() {
        // launchctl-typical daemon name not in the curated list; if the
        // host happens to have it as a real LaunchDaemon, it should classify
        // as systemManaged. We can't assert the host's plist contents in a
        // unit test, but we can at least exercise the API contract.
        let curated = SecurityAgents.classify(name: "falconctl", bundleID: nil)
        if case .curated = curated { } else { XCTFail("falconctl should classify as curated") }

        let unknown = SecurityAgents.classify(name: "definitely-not-a-real-process-xyz", bundleID: nil)
        if case .unknown = unknown { } else { XCTFail("Random name should be unknown") }
    }
}
