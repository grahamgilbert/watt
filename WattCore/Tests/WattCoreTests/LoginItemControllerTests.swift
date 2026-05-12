import XCTest
@testable import WattUI

@MainActor
final class LoginItemControllerTests: XCTestCase {
    func testUserChoiceFlagPersistsAcrossInstances() {
        let suite = "watt-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = LoginItemController(defaults: defaults)
        XCTAssertFalse(first.userHasMadeExplicitChoice,
                       "Fresh defaults should report no explicit user choice")
        // setEnabled records an explicit choice even if the underlying
        // SMAppService call is a no-op in this test environment.
        first.setEnabled(false)
        XCTAssertTrue(first.userHasMadeExplicitChoice)

        let second = LoginItemController(defaults: defaults)
        XCTAssertTrue(second.userHasMadeExplicitChoice,
                      "Explicit-choice flag must persist across controller instances")
    }

    func testRegisterDefaultIsNoopAfterUserMadeChoice() {
        let suite = "watt-tests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create test defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "watt.loginItem.userHasMadeChoice")

        let controller = LoginItemController(defaults: defaults)
        XCTAssertTrue(controller.userHasMadeExplicitChoice)
        // Should not throw and should not flip userHasMadeExplicitChoice off.
        controller.registerDefaultIfNeeded()
        XCTAssertTrue(controller.userHasMadeExplicitChoice)
    }
}
