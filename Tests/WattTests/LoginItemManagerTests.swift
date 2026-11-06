import ServiceManagement
import XCTest
@testable import Watt

final class LoginItemManagerTests:XCTestCase {
    @MainActor func testConstructionOnlyReadsExistingState() async {
        withDefaults { defaults in
            for state in [SMAppService.Status.notRegistered,.enabled,.requiresApproval,.notFound] {
                let service=MockLoginItemService(status:state)
                let manager=LoginItemManager(isAvailable:true,defaults:defaults,service:service)
                XCTAssertEqual(manager.status,state)
                XCTAssertNil(defaults.object(forKey:LoginItemManager.setupKey))
                XCTAssertEqual(service.mutations,0)
            }
        }
    }

    @MainActor func testFirstLaunchEnablesOnceAcrossRelaunches() async {
        withDefaults { defaults in
            let service=MockLoginItemService()
            let manager=LoginItemManager(isAvailable:true,defaults:defaults,service:service)
            manager.applyDefaultIfNeeded()
            XCTAssertTrue(manager.isEnabled)
            XCTAssertTrue(defaults.bool(forKey:LoginItemManager.setupKey))
            manager.applyDefaultIfNeeded()
            LoginItemManager(isAvailable:true,defaults:defaults,service:service).applyDefaultIfNeeded()
            XCTAssertEqual(service.registrations,1)
            XCTAssertEqual(service.unregistrations,0)
            XCTAssertEqual(service.settingsOpened,0)
        }
    }

    @MainActor func testExplicitDisableSurvivesRelaunch() async {
        withDefaults { defaults in
            let service=MockLoginItemService()
            let manager=LoginItemManager(isAvailable:true,defaults:defaults,service:service)
            manager.applyDefaultIfNeeded()
            manager.setEnabled(false)
            XCTAssertFalse(manager.isEnabled)
            let relaunched=LoginItemManager(isAvailable:true,defaults:defaults,service:service)
            relaunched.applyDefaultIfNeeded()
            XCTAssertFalse(relaunched.isEnabled)
            XCTAssertEqual(service.registrations,1)
            XCTAssertEqual(service.unregistrations,1)
        }
    }

    @MainActor func testExplicitDisableBeforeDefaultApplicationPreventsRegistration() async {
        withDefaults { defaults in
            let service=MockLoginItemService()
            let manager=LoginItemManager(isAvailable:true,defaults:defaults,service:service)
            manager.setEnabled(false)
            LoginItemManager(isAvailable:true,defaults:defaults,service:service).applyDefaultIfNeeded()
            XCTAssertEqual(service.mutations,0)
            XCTAssertTrue(defaults.bool(forKey:LoginItemManager.setupKey))
        }
    }

    @MainActor func testSystemSettingsOptOutIsRespectedAcrossRelaunch() async {
        for disabledState in [SMAppService.Status.notRegistered,.requiresApproval] {
            withDefaults { defaults in
                let service=MockLoginItemService()
                LoginItemManager(isAvailable:true,defaults:defaults,service:service).applyDefaultIfNeeded()
                service.status=disabledState
                let relaunched=LoginItemManager(isAvailable:true,defaults:defaults,service:service)
                relaunched.applyDefaultIfNeeded()
                XCTAssertEqual(relaunched.status,disabledState)
                XCTAssertFalse(relaunched.isEnabled)
                XCTAssertEqual(relaunched.needsApproval,disabledState == .requiresApproval)
                XCTAssertEqual(service.registrations,1)
                XCTAssertEqual(service.settingsOpened,0)
            }
        }
    }

    @MainActor func testExistingRegistrationOrUnavailableServiceIsAdoptedWithoutRegistration() async {
        for existingState in [SMAppService.Status.enabled,.requiresApproval,.notFound] {
            withDefaults { defaults in
                let service=MockLoginItemService(status:existingState)
                let manager=LoginItemManager(isAvailable:true,defaults:defaults,service:service)
                manager.applyDefaultIfNeeded()
                XCTAssertEqual(manager.status,existingState)
                XCTAssertEqual(service.mutations,0)
                XCTAssertTrue(defaults.bool(forKey:LoginItemManager.setupKey))
                service.status = .notRegistered
                LoginItemManager(isAvailable:true,defaults:defaults,service:service).applyDefaultIfNeeded()
                XCTAssertEqual(service.mutations,0)
            }
        }
    }

    @MainActor func testFailedDefaultRegistrationNeedsExplicitRetry() async {
        withDefaults { defaults in
            let service=MockLoginItemService()
            service.registrationError=LoginItemTestError.failed
            let manager=LoginItemManager(isAvailable:true,defaults:defaults,service:service)
            manager.applyDefaultIfNeeded()
            XCTAssertFalse(manager.isEnabled)
            XCTAssertNotNil(manager.lastError)
            XCTAssertTrue(defaults.bool(forKey:LoginItemManager.setupKey))
            manager.applyDefaultIfNeeded()
            let relaunched=LoginItemManager(isAvailable:true,defaults:defaults,service:service)
            relaunched.applyDefaultIfNeeded()
            XCTAssertEqual(service.registrations,1)
            service.registrationError=nil
            manager.setEnabled(true)
            XCTAssertTrue(manager.isEnabled)
            XCTAssertNil(manager.lastError)
            XCTAssertEqual(service.registrations,2)
        }
    }

    @MainActor func testFailedDisableKeepsActualEnabledStateAndExplicitRetryClearsError() async {
        withDefaults { defaults in
            let service=MockLoginItemService(status:.enabled)
            service.unregistrationError=LoginItemTestError.failed
            let manager=LoginItemManager(isAvailable:true,defaults:defaults,service:service)
            manager.setEnabled(false)
            XCTAssertTrue(manager.isEnabled)
            XCTAssertNotNil(manager.lastError)
            LoginItemManager(isAvailable:true,defaults:defaults,service:service).applyDefaultIfNeeded()
            XCTAssertEqual(service.unregistrations,1)
            service.unregistrationError=nil
            manager.setEnabled(false)
            XCTAssertFalse(manager.isEnabled)
            XCTAssertNil(manager.lastError)
            XCTAssertEqual(service.unregistrations,2)
        }
    }

    @MainActor func testUnavailableBuildNeitherChangesSystemNorConsumesDefaultAttempt() async {
        withDefaults { defaults in
            let service=MockLoginItemService()
            let manager=LoginItemManager(isAvailable:false,defaults:defaults,service:service)
            manager.applyDefaultIfNeeded()
            manager.setEnabled(true)
            manager.setEnabled(false)
            XCTAssertEqual(service.mutations,0)
            XCTAssertNil(defaults.object(forKey:LoginItemManager.setupKey))
            LoginItemManager(isAvailable:true,defaults:defaults,service:service).applyDefaultIfNeeded()
            XCTAssertEqual(service.registrations,1)
        }
    }

    @MainActor func testRefreshAdoptsSystemStateWithoutChangingIt() async {
        withDefaults { defaults in
            let service=MockLoginItemService()
            let manager=LoginItemManager(isAvailable:true,defaults:defaults,service:service)
            for state in [SMAppService.Status.enabled,.requiresApproval,.notFound,.notRegistered] {
                service.status=state
                manager.refreshStatus()
                XCTAssertEqual(manager.status,state)
                XCTAssertEqual(manager.isEnabled,state == .enabled)
                XCTAssertEqual(manager.needsApproval,state == .requiresApproval)
            }
            XCTAssertEqual(service.mutations,0)
            XCTAssertNil(defaults.object(forKey:LoginItemManager.setupKey))
        }
    }

    @MainActor func testEnablingRevokedPermissionOpensSettingsInsteadOfReregistering() async {
        withDefaults { defaults in
            let service=MockLoginItemService(status:.requiresApproval)
            let manager=LoginItemManager(isAvailable:true,defaults:defaults,service:service)
            manager.setEnabled(true)
            XCTAssertFalse(manager.isEnabled)
            XCTAssertTrue(manager.needsApproval)
            XCTAssertEqual(service.settingsOpened,1)
            XCTAssertEqual(service.registrations,0)
            XCTAssertEqual(service.unregistrations,0)
        }
    }

    @MainActor private func withDefaults(_ body:(UserDefaults)->Void) {
        let suite="watt-login-item-tests-"+UUID().uuidString
        let defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        body(defaults)
    }
}

@MainActor private final class MockLoginItemService:LoginItemService {
    var status:SMAppService.Status
    var registrations=0
    var unregistrations=0
    var settingsOpened=0
    var registrationError:Error?
    var unregistrationError:Error?
    var mutations:Int {registrations+unregistrations+settingsOpened}

    init(status:SMAppService.Status = .notRegistered) {self.status=status}
    func register() throws {
        registrations+=1
        if let registrationError {throw registrationError}
        status = .enabled
    }
    func unregister() throws {
        unregistrations+=1
        if let unregistrationError {throw unregistrationError}
        status = .notRegistered
    }
    func openSettings() {settingsOpened+=1}
}

private enum LoginItemTestError:Error {case failed}
