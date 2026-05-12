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
    public func evaluate() async {
        state = .checking
        let status = await client.currentStatus()
        switch status {
        case .enabled:
            await pingForVersion()
        case .requiresApproval:
            state = .needsInstall(reason: .requiresApproval)
        case .notRegistered, .notFound:
            state = .needsInstall(reason: .notInstalled)
        @unknown default:
            state = .needsInstall(reason: .notInstalled)
        }
    }

    /// User asked us to (re)install. Triggers the SMAppService prompt and
    /// then re-evaluates.
    public func install() async {
        state = .installing
        do {
            try await client.registerIfNeeded()
        } catch HelperClient.HelperError.requiresApproval {
            state = .needsInstall(reason: .requiresApproval)
            return
        } catch {
            state = .installFailed(message: error.localizedDescription)
            return
        }
        // Give launchd a moment to spin the helper up, then ping.
        try? await Task.sleep(for: .seconds(1))
        await pingForVersion()
    }

    /// User declined to install. Quit the app.
    public func quit() {
        logger.info("HelperGate quit requested")
        NSApplication.shared.terminate(nil)
    }

    private func pingForVersion() async {
        do {
            let response = try await client.hello()
            if response.protocolVersion == expectedProtocolVersion {
                state = .ready
                logger.info("Helper ready (v\(response.helperVersion), proto \(response.protocolVersion))")
            } else {
                state = .needsInstall(reason: .staleProtocol(
                    installed: response.protocolVersion,
                    expected: expectedProtocolVersion
                ))
            }
        } catch {
            state = .needsInstall(reason: .unreachable(message: error.localizedDescription))
        }
    }
}
