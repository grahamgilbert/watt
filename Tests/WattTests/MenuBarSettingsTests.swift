import XCTest
@testable import Watt

final class MenuBarSettingsTests:XCTestCase {
    func testAppearanceSurvivesRelaunchAndInvalidWidthRecovers() async {
        await MainActor.run {
            let suite="watt-tests-"+UUID().uuidString
            let defaults=UserDefaults(suiteName:suite)!
            defer {defaults.removePersistentDomain(forName:suite)}
            let settings=MenuBarSettings(defaults:defaults)
            settings.width=64;settings.layout="Numeric";settings.primary="Battery power";settings.secondary="Network";settings.color=true;settings.network=false;settings.networkNumbers=false;settings.metricNumbers=false;settings.graphStyle="Lines"
            let restored=MenuBarSettings(defaults:defaults)
            XCTAssertEqual(restored.width,64);XCTAssertEqual(restored.layout,"Numeric")
            XCTAssertEqual(restored.primary,"Battery power");XCTAssertEqual(restored.secondary,"Network")
            XCTAssertTrue(restored.color);XCTAssertFalse(restored.network)
            XCTAssertFalse(restored.networkNumbers);XCTAssertFalse(restored.metricNumbers);XCTAssertEqual(restored.graphStyle,"Lines")
            defaults.set(-100,forKey:"menu.width")
            XCTAssertEqual(MenuBarSettings(defaults:defaults).width,52)
        }
    }
    func testNetworkOverlayFormattingKeepsDirectionIndependentAndRejectsMissing() {
        XCTAssertEqual(compactNetworkRate(0),"0B")
        XCTAssertEqual(compactNetworkRate(61.3*1024),"61K")
        XCTAssertEqual(compactNetworkRate(1024),"1K")
        XCTAssertEqual(compactNetworkRate(12.5*1048576),"12M")
        XCTAssertEqual(compactNetworkRate(150*1048576),"150M")
        XCTAssertEqual(compactNetworkRate(.nan),"—")
    }
}
