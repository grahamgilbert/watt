import XCTest
@testable import WattAnalysis
@testable import WattModels

/// Regression tests for the case the v1 reports missed: a root-owned
/// security agent (Falcon, Cyberhaven, etc.) that `proc_pid_rusage` can't
/// read but `proc_pidpath` and `proc_name` can. The fix records these
/// processes with zeroed CPU/energy/IO numbers but full identity, then the
/// always-include rule in `ProcessCorrelator` surfaces them in suspects.
final class RootOwnedAgentSurfacingTests: XCTestCase {

    func testRootOwnedAgentSurfacesEvenWithoutCpuOrEnergyData() {
        // Background workload: a normal user process burning CPU.
        // Foreground "agent": a root-owned process whose CPU/energy can't
        // be read (rusage failed, so the deltas are zero), but whose
        // executable path is known.
        let drain = Fixtures.steadyDrain(startPercent: 95, ratePctPerHour: 30, count: 30, step: 10)
        let processed = drain.map { sample -> SamplePoint in
            var s = sample
            s.processes = [
                ProcessPoint(
                    pid: 100, name: "loud-build", bundleID: nil,
                    cpuTimeDelta: 5, energyNanojoulesDelta: 5_000_000_000,
                    billedEnergyDelta: 0,
                    diskReadBytesDelta: 0, diskWriteBytesDelta: 0,
                    pageinsDelta: 0, residentBytes: 0
                ),
                ProcessPoint(
                    pid: 579,
                    name: "com.crowdstrike.falcon.Agent",
                    bundleID: nil,
                    executablePath: "/Library/SystemExtensions/4328538A-5169-4EA1-A529-38B69111A73A/com.crowdstrike.falcon.Agent.systemextension/Contents/MacOS/com.crowdstrike.falcon.Agent",
                    cpuTimeDelta: 0,
                    energyNanojoulesDelta: 0,
                    billedEnergyDelta: 0,
                    diskReadBytesDelta: 0,
                    diskWriteBytesDelta: 0,
                    pageinsDelta: 0,
                    residentBytes: 0
                )
            ]
            return s
        }
        let result = ProcessCorrelator().correlate(samples: processed)

        XCTAssertTrue(
            result.suspects.contains { $0.pid == 579 },
            "Root-owned agent must appear in suspects via the always-include rule"
        )
        // It should also be present in the dedicated securityAgents list.
        XCTAssertTrue(
            result.securityAgents.contains { $0.pid == 579 },
            "Root-owned agent must appear in the dedicated securityAgents result"
        )
    }

    func testCuratedNameMatchStillWorksForLightweightHelpers() {
        // A process named falconctl with no executable path (rusage worked
        // because we own it, no system-extension path). The curated registry
        // should still match by name fragment.
        let classification = SecurityAgents.classify(
            name: "falconctl",
            bundleID: nil,
            executablePath: nil
        )
        if case .curated(let def) = classification {
            XCTAssertEqual(def.displayName, "CrowdStrike Falcon")
        } else {
            XCTFail("falconctl should classify as curated by name")
        }
    }

    func testOfficeLicensingHelperIsNotFlagged() {
        // The previous matcher fuzzy-matched "office" / "microsoft" and
        // would flag this process as Microsoft Defender. The new path-based
        // matcher must not.
        let classification = SecurityAgents.classify(
            name: "OfficeLicensingHelper",
            bundleID: "com.microsoft.OfficeLicensingHelper",
            executablePath: "/Library/PrivilegedHelperTools/com.microsoft.OfficeLicensingHelper"
        )
        // Could legitimately match if Microsoft Defender's bundle ID appears,
        // but com.microsoft.OfficeLicensingHelper does not match
        // com.microsoft.wdav.* or com.microsoft.dlp.* (the only Microsoft
        // entries in the curated list). And the OfficeLicensingHelper isn't
        // a system extension. So it must classify as unknown.
        if case .unknown = classification {
            // ok
        } else {
            XCTFail("OfficeLicensingHelper must NOT classify as a security agent (got \(classification))")
        }
    }
}
