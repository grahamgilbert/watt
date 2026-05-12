import SwiftUI
import WattHelperClient

/// Shown when the privileged helper is not installed (or its protocol
/// version doesn't match). The app refuses to do anything until the user
/// either approves the install or quits.
public struct HelperInstallSheet: View {
    let gate: HelperGate

    public init(gate: HelperGate) { self.gate = gate }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Watt needs to install a background helper")
                        .font(.title3)
                        .bold()
                    Text(headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Why").font(.headline)
                Text(
                    "Endpoint Security extensions like CrowdStrike Falcon and Cyberhaven"
                    + " are deliberately invisible to unprivileged processes. Watt cannot"
                    + " measure their CPU, memory, or energy without a tiny helper running"
                    + " as root."
                )
                .font(.body)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What gets installed").font(.headline)
                Text(
                    "A LaunchDaemon at /Library/LaunchDaemons/com.grahamgilbert.watt.helper.plist"
                    + " that exposes a single XPC service. The helper only reads process"
                    + " telemetry — no keystrokes, no network access, no file contents."
                )
                .font(.body)
                .foregroundStyle(.secondary)
            }

            if case .installFailed(let message) = gate.state {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button(role: .destructive) {
                    gate.quit()
                } label: {
                    Text("Quit Watt")
                }
                Button {
                    Task { await gate.install() }
                } label: {
                    if case .installing = gate.state {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(actionLabel)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(installing)
            }
        }
        .padding(28)
        .frame(width: 540)
    }

    private var installing: Bool {
        if case .installing = gate.state { return true }
        return false
    }

    private var headline: String {
        switch gate.state {
        case .needsInstall(.notInstalled):
            return "First-launch install. You'll be asked for your administrator password."
        case .needsInstall(.requiresApproval):
            return "macOS is waiting for your approval. We'll deep-link you to System Settings → Login Items."
        case .needsInstall(.staleProtocol(let installed, let expected)):
            return "An older helper (protocol v\(installed)) is installed. Watt needs protocol v\(expected). Re-install to update."
        case .needsInstall(.unreachable(let message)):
            return "Couldn't reach the installed helper: \(message)"
        case .installing:
            return "Installing…"
        case .installFailed:
            return "The install failed. Try again or quit."
        case .checking, .ready:
            return ""
        }
    }

    private var actionLabel: String {
        switch gate.state {
        case .needsInstall(.requiresApproval): return "Open System Settings"
        case .needsInstall(.staleProtocol):    return "Re-install helper"
        case .needsInstall(.unreachable):      return "Re-install helper"
        case .installFailed:                   return "Try again"
        default:                               return "Install"
        }
    }
}
