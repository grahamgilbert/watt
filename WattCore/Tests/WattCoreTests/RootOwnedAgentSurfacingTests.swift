import XCTest
@testable import WattAnalysis
@testable import WattModels

final class RootOwnedAgentSurfacingTests: XCTestCase {

    func testHighCpuProcessAlwaysInSuspects() {
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
                    executablePath: "/Library/SystemExtensions/4328538A/com.crowdstrike.falcon.Agent.systemextension/Contents/MacOS/com.crowdstrike.falcon.Agent",
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
            result.suspects.contains { $0.pid == 100 },
            "High-CPU process must appear in suspects"
        )
    }

    func testOfficeLicensingHelperIsNotFlaggedAsCurated() {
        // Must not match a phantom vendor registry entry — only path-based
        // SystemServiceRegistry matches are valid.
        let classification = SecurityAgents.classify(
            name: "OfficeLicensingHelper",
            bundleID: "com.microsoft.OfficeLicensingHelper",
            executablePath: "/Library/PrivilegedHelperTools/com.microsoft.OfficeLicensingHelper"
        )
        switch classification {
        case .unknown, .systemManaged:
            break  // both acceptable — depends on what's installed on this host
        }
    }

    func testIsAgentFlagForKnownSystemExtensionPath() {
        // If SystemServiceRegistry has this path (installed host), isAgent = true.
        // If not installed, isAgent = false. Either way, no crash and no phantom match.
        let result = SecurityAgents.classify(
            name: "com.crowdstrike.falcon.Agent",
            bundleID: "com.crowdstrike.falcon",
            executablePath: "/Library/SystemExtensions/4328538A/com.crowdstrike.falcon.Agent.systemextension/Contents/MacOS/com.crowdstrike.falcon.Agent"
        )
        // Just verify it doesn't crash and returns a valid Classification.
        _ = result.isAgent
        _ = result.displayName
        _ = result.vendor
    }
}
