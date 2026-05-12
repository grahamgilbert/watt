import SwiftUI
import WattSampling

public struct MenuBarView: View {
    @Bindable var coordinator: SamplingCoordinator
    let openReport: () -> Void

    public init(coordinator: SamplingCoordinator, openReport: @escaping () -> Void) {
        self.coordinator = coordinator
        self.openReport = openReport
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

    @ViewBuilder
    private var statRows: some View {
        let s = coordinator.snapshot
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            row(label: "Battery", value: batteryString(s))
            row(label: "Drain rate", value: drainString(s))
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
        guard s.drainRatePctPerHour > 0.5 else { return "—" }
        return "−\(Int(s.drainRatePctPerHour.rounded())) %/h"
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
