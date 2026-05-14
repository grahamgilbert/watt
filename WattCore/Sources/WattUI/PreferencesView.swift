import AppKit
import SwiftUI
import UserNotifications

public struct PreferencesView: View {
    @Bindable var prefs: WattPreferences
    let loginItem: LoginItemController
    @State private var authStatus: UNAuthorizationStatus = .notDetermined

    public init(prefs: WattPreferences, loginItem: LoginItemController) {
        self.prefs = prefs
        self.loginItem = loginItem
    }

    public var body: some View {
        Form {
            Section("General") {
                Toggle(isOn: launchAtLoginBinding) {
                    Text("Launch at login")
                }
                if loginItem.status == .requiresApproval {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Approval required in System Settings.")
                                .font(.callout)
                            Button("Open Login Items Settings") {
                                loginItem.openSystemSettings()
                            }
                            .font(.callout)
                            .buttonStyle(.link)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Notifications") {
                Toggle(isOn: $prefs.notifyOnEpisodeReady) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Notify when a report is ready")
                        Text("Sends a notification when Watt finishes generating a high-energy episode report.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(authStatus == .denied)

                if authStatus == .denied {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Notifications are blocked in System Settings.")
                                .font(.callout)
                            Button("Open Notification Settings") {
                                openNotificationSettings()
                            }
                            .font(.callout)
                            .buttonStyle(.link)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding(.vertical, 8)
        .task { await checkAuthStatus() }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        )
    }

    private func checkAuthStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authStatus = settings.authorizationStatus
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
