import AppKit
import SwiftUI
import WattSampling

public struct MenuBarView: View {
    let coordinator: SamplingCoordinator
    let loginItem: LoginItemController
    let openReport: () -> Void
    let onAdHocReport: (TimeInterval) -> Void

    public init(
        coordinator: SamplingCoordinator,
        loginItem: LoginItemController,
        openReport: @escaping () -> Void,
        onAdHocReport: @escaping (TimeInterval) -> Void = { _ in }
    ) {
        self.coordinator = coordinator
        self.loginItem = loginItem
        self.openReport = openReport
        self.onAdHocReport = onAdHocReport
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Watt")
                    .font(.headline)
                Spacer()
                if coordinator.snapshot.inEpisode {
                    Label("Drain episode", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Divider()
            statRows
            Divider()
            Toggle("Launch at login", isOn: launchAtLoginBinding)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
            if loginItem.status == .requiresApproval {
                Button("Approve in System Settings…") {
                    loginItem.openSystemSettings()
                }
                .font(.caption)
                .controlSize(.small)
            }
            Divider()
            Menu {
                Button("Last 15 minutes")  { onAdHocReport(15 * 60) }
                Button("Last 30 minutes")  { onAdHocReport(30 * 60) }
                Button("Last 60 minutes")  { onAdHocReport(60 * 60) }
                Button("Last 2 hours")     { onAdHocReport(2 * 3600) }
            } label: {
                Label("Investigate recent activity…", systemImage: "magnifyingglass")
            }
            .menuStyle(.borderlessButton)
            Divider()
            HStack {
                Button("Open Reports", action: openReport)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { loginItem.isEnabled },
            set: { loginItem.setEnabled($0) }
        )
    }

    @ViewBuilder
    private var statRows: some View {
        let s = coordinator.snapshot
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row(label: "Battery", value: batteryString(s))
            row(label: "Drain rate", value: drainString(s))
            row(label: "Energy", value: energyString(s))
            row(label: "CPU", value: percentString(s.systemCPUUsage))
            row(label: "Memory pressure", value: "\(Int(s.memoryPressurePct.rounded()))%")
            if s.maxFanRPM > 0 {
                row(label: "Max fan", value: "\(Int(s.maxFanRPM.rounded())) RPM")
            }
            if let temp = s.hottestSensorCelsius, temp > 0 {
                row(label: "Hottest sensor", value: String(format: "%.1f °C", temp))
            }
            row(label: "Thermal", value: thermalLabel(s.thermalState))
            row(label: "FS events", value: "\(Int(s.fsEventsRate.rounded()))/s")
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func row(label: String, value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func batteryString(_ s: SamplingCoordinator.Snapshot) -> String {
        guard !s.batteryPercent.isNaN else { return "—" }
        let charging = s.isCharging ? " ⚡︎" : ""
        return "\(Int(s.batteryPercent.rounded()))%\(charging)"
    }

    private func drainString(_ s: SamplingCoordinator.Snapshot) -> String {
        guard s.drainRatePctPerHour > 0.5 else {
            return s.isCharging ? "(on AC)" : "—"
        }
        return "−\(Int(s.drainRatePctPerHour.rounded())) %/h"
    }

    private func energyString(_ s: SamplingCoordinator.Snapshot) -> String {
        guard s.systemEnergyWatts > 0 else { return "—" }
        if s.systemEnergyWatts < 10 {
            return String(format: "%.1f W", s.systemEnergyWatts)
        }
        return "\(Int(s.systemEnergyWatts.rounded())) W"
    }

    private func percentString(_ unit: Double) -> String {
        "\(Int((unit * 100).rounded()))%"
    }

    private func thermalLabel(_ rawValue: Int) -> String {
        switch rawValue {
        case 0: return "nominal"
        case 1: return "fair"
        case 2: return "serious"
        case 3: return "critical"
        default: return "unknown"
        }
    }
}
