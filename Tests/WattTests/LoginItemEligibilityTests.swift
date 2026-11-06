import Foundation
import Security
import XCTest
@testable import Watt

final class LoginItemEligibilityTests:XCTestCase {
    @MainActor private func requirement(path:String="/private/tmp/Watt.app",bundleID:String?="com.grahamgilbert.Watt",
                                        signingID:String?="com.grahamgilbert.Watt",team:String?="A1B2C3D4E5")->SecRequirement? {
        LoginItemManager.signingRequirement(bundleURL:URL(fileURLWithPath:path),bundleIdentifier:bundleID,
            signingIdentifier:signingID,team:team)
    }
    @MainActor func testValidAppIdentityProducesAnAppleSigningRequirement() async {
        XCTAssertNotNil(requirement())
    }
    @MainActor func testUnbundledOrMismatchedIdentitiesCannotProduceAnEligibleRequirement() async {
        XCTAssertNil(requirement(path:"/private/tmp/Watt"))
        XCTAssertNil(requirement(path:"/private/tmp/Watt.xctest"))
        XCTAssertNil(requirement(bundleID:nil))
        XCTAssertNil(requirement(bundleID:"dev.watt.local"))
        XCTAssertNil(requirement(signingID:nil))
        XCTAssertNil(requirement(signingID:"com.grahamgilbert.Watt.EnergyHelper"))
    }
    @MainActor func testMissingOrMalformedTeamsAreRejectedBeforeRequirementCreation() async {
        XCTAssertNil(requirement(team:nil))
        for team in ["","SHORT","A1B2C3D4E56","abcdefghij","A1B2C3D4\"5"] {
            XCTAssertNil(requirement(team:team))
        }
    }
    @MainActor func testTheUnbundledTestRunnerIsNotEligible() async {
        XCTAssertFalse(LoginItemManager.isSignedApp)
    }
}
