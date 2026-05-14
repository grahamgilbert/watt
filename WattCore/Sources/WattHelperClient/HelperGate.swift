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

        // Fast ping (3 s timeout) — catches the normal case where the helper
        // is alive and just needs a moment to respond.
        if let result = await pingForVersionResult(attempts: 2, timeout: 3, delayBetween: .seconds(1)) {
            logger.info("evaluate: fast ping succeeded")
            state = result
            return
        }

        // Ping missed. Check SMAppService status to decide next step.
        let status = await client.currentStatus()
        logger.info("evaluate: fast ping failed, SMAppService.status=\(String(describing: status))")

        switch status {
        case .requiresApproval:
            state = .needsInstall(reason: .requiresApproval)
            return
        case .notRegistered, .notFound:
            state = .needsInstall(reason: .notInstalled)
            return
        case .enabled:
            break
        @unknown default:
            state = .needsInstall(reason: .notInstalled)
            return
        }

        // Status is .enabled but helper isn't answering. Two sub-cases:
        // (a) Normal cold start — helper is starting up, give it a few more seconds.
        // (b) Stale BTM entry — helper "runs" from old DerivedData path, will never answer.
        // We can't distinguish them until we try. Give it one more patient ping,
        // then immediately do unregister+register to fix the stale BTM case.
        if let result = await pingForVersionResult(attempts: 2, timeout: 5, delayBetween: .seconds(2)) {
            state = result
            return
        }

        // Still failing — assume stale BTM entry. Full unregister → register
        // cycle flushes the old path and writes a fresh absolute-path entry
        // anchored to /Applications/Watt.app.
        logger.info("evaluate: helper unresponsive, cycling registration to clear stale BTM entry")
        await client.unregister()
        try? await Task.sleep(for: .seconds(2))
        try? await client.forceRegister()
        try? await Task.sleep(for: .seconds(4))

        if let result = await pingForVersionResult(attempts: 3, timeout: 5, delayBetween: .seconds(2)) {
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
    private func pingForVersionResult(attempts: Int = 4, timeout: TimeInterval = 10, delayBetween: Duration = .seconds(2)) async -> State? {
        for attempt in 1...attempts {
            do {
                let response = try await client.hello(timeout: timeout)
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
