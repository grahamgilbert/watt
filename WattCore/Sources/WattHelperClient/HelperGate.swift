import AppKit
import Foundation
import Observation
import os.log
import ServiceManagement

private let logger = Logger(subsystem: "com.grahamgilbert.watt", category: "helper-gate")

/// Decides whether the app is allowed to do anything. The helper is
/// mandatory: if it isn't installed, or if the installed helper's protocol
/// version doesn't match the app's, the user is asked to install/upgrade
/// it. Refusing exits the app.
@MainActor
@Observable
public final class HelperGate {
    public enum State: Equatable, Sendable {
        case checking
        case ready
        case needsInstall(reason: NeedsInstallReason)
        case installing
        case installFailed(message: String)
    }

    public enum NeedsInstallReason: Equatable, Sendable {
        case notInstalled
        case requiresApproval
        case staleProtocol(installed: Int, expected: Int)
        case unreachable(message: String)
        case wrongLocation(current: String)
    }

    public private(set) var state: State = .checking

    private let client: HelperClient
    private let expectedProtocolVersion: Int

    public init(client: HelperClient = HelperClient(), expectedProtocolVersion: Int) {
        self.client = client
        self.expectedProtocolVersion = expectedProtocolVersion
    }

    /// Run the gate. Should be called once at app launch — the rest of the
    /// app must wait for `state == .ready` before doing anything.
    ///
    /// Strategy: XPC ping is authoritative. If the helper answers correctly,
    /// we're ready regardless of what SMAppService.status says — this handles
    /// the most common dev case where the bundle was replaced (new Debug build
    /// copied to /Applications) but the running helper is still alive and fine.
    /// Only when the ping fails do we consult SMAppService status to pick the
    /// right error/recovery path.
    public func evaluate() async {
        state = .checking

        // SMAppService only works when the app is in /Applications. Check
        // this before anything else so the error is clear.
        let bundlePath = Bundle.main.bundleURL.path
        let isInApplications = bundlePath.hasPrefix("/Applications/")
        if !isInApplications {
            logger.error("App is not in /Applications: \(bundlePath)")
            state = .needsInstall(reason: .wrongLocation(current: bundlePath))
            return
        }

        // Ping first — the helper may already be alive even if SMAppService
        // says the registration is stale (e.g. binary was just replaced in
        // /Applications). Avoids showing the sheet on every dev build.
        if let result = await pingForVersionResult(attempts: 2, delayBetween: .seconds(1)) {
            logger.info("evaluate: ping succeeded early, skipping SMAppService check")
            state = result
            return
        }

        // Ping missed on first two fast tries. Check what SMAppService thinks.
        let status = await client.currentStatus()
        logger.info("evaluate: early ping failed, SMAppService.status=\(String(describing: status))")

        switch status {
        case .requiresApproval:
            // User must approve in Login Items — no amount of retrying helps.
            state = .needsInstall(reason: .requiresApproval)
            return
        case .notRegistered, .notFound:
            // Never been installed. Skip further pings; show install UI.
            state = .needsInstall(reason: .notInstalled)
            return
        case .enabled:
            // Helper is registered. launchd should start it on first Mach IPC.
            // Retry pings a bit longer — the daemon may be cold-starting.
            break
        @unknown default:
            state = .needsInstall(reason: .notInstalled)
            return
        }

        // Status is .enabled — retry the ping with more patience.
        if let result = await pingForVersionResult() {
            state = result
            return
        }

        // Still failing. The most likely cause: the app bundle was replaced
        // (rm -rf + ditto) and launchd's BTM entry points at the old path.
        // Silently re-register to pick up the new binary, then give it 5 s
        // to start before the final retry.
        logger.info("evaluate: extended ping failed, attempting silent forceRegister")
        try? await client.forceRegister()
        try? await Task.sleep(for: .seconds(5))

        if let result = await pingForVersionResult(attempts: 4, delayBetween: .seconds(2)) {
            state = result
            return
        }

        state = .needsInstall(reason: .unreachable(message: "Helper registered but not responding"))
    }

    /// User asked us to (re)install. Triggers the SMAppService prompt and
    /// then re-evaluates.
    public func install() async {
        logger.info("HelperGate.install() starting; state=\(String(describing: self.state))")
        state = .installing

        // Always unregister first to clear any stale BTM entry (e.g. a
        // relative path from a DerivedData build). Wait 2 s after unregister
        // before calling register() — launchd needs time to release the mach
        // service slot or register() returns EPERM.
        logger.info("HelperGate.install() unregistering to clear BTM entry")
        await client.unregister()
        try? await Task.sleep(for: .seconds(2))

        do {
            try await client.forceRegister()
            logger.info("HelperGate.install() forceRegister succeeded")
        } catch HelperClient.HelperError.requiresApproval {
            logger.info("HelperGate.install() requires approval")
            state = .needsInstall(reason: .requiresApproval)
            return
        } catch {
            logger.error("HelperGate.install() failed: \(error.localizedDescription)")
            state = .installFailed(message: error.localizedDescription)
            return
        }
        // Give launchd a moment to spin the helper up, then ping.
        try? await Task.sleep(for: .seconds(2))
        await pingForVersion()
    }

    /// User declined to install. Quit the app.
    public func quit() {
        logger.info("HelperGate quit requested")
        NSApplication.shared.terminate(nil)
    }

    /// Pings the helper up to `attempts` times. Returns the resolved `State`
    /// (.ready or .needsInstall(.staleProtocol)) on success, nil if all pings
    /// time out or fail with an XPC error.
    private func pingForVersionResult(attempts: Int = 4, delayBetween: Duration = .seconds(2)) async -> State? {
        for attempt in 1...attempts {
            do {
                let response = try await client.hello(timeout: 10)
                logger.info("ping attempt \(attempt) succeeded proto=\(response.protocolVersion)")
                if response.protocolVersion == expectedProtocolVersion {
                    return .ready
                }
                return .needsInstall(reason: .staleProtocol(
                    installed: response.protocolVersion,
                    expected: expectedProtocolVersion
                ))
            } catch {
                logger.info("ping attempt \(attempt) failed: \(error.localizedDescription, privacy: .public)")
                if attempt < attempts {
                    try? await Task.sleep(for: delayBetween)
                }
            }
        }
        return nil
    }

    private func pingForVersion() async {
        if let result = await pingForVersionResult(attempts: 5) {
            state = result
        } else {
            state = .needsInstall(reason: .unreachable(message: "Helper did not respond after 5 attempts"))
        }
    }
}
