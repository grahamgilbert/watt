import SwiftData
import SwiftUI
import WattAI
import WattAnalysis
import WattHelperClient
import WattHelperProtocol
import WattModels
import WattSampling
import WattUI

@main
struct WattApp: App {
    @Environment(\.openWindow) private var openWindow
    private let container: ModelContainer
    @State private var coordinator: SamplingCoordinator
    @State private var loginItem: LoginItemController
    @State private var progress: ReportProgress
    @State private var helperGate: HelperGate
    @State private var samplingStarted = false
    private let reportCoordinator: ReportCoordinator

    init() {
        let container: ModelContainer
        do {
            container = try WattStore.makeContainer()
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
        self.container = container
        let writer = SamplingWriter(modelContainer: container)
        let coordinator = SamplingCoordinator(writer: writer)
        self._coordinator = State(initialValue: coordinator)
        self._loginItem = State(initialValue: LoginItemController())
        self._progress = State(initialValue: ReportProgress())
        self._helperGate = State(initialValue: HelperGate(
            expectedProtocolVersion: WattHelperProtocolVersion
        ))
        self.reportCoordinator = ReportCoordinator(writer: writer)
    }

    private func runAdHoc(lookback: TimeInterval) {
        let label = "Generating report for the last \(Int(lookback / 60)) min…"
        progress.startGenerating(label: label)
        let coordinator = reportCoordinator
        let progress = progress
        Task { @MainActor in
            let id = await coordinator.generateAdHocReport(lookback: lookback)
            if let id {
                progress.finish(label: "Report ready", episodeID: id)
            } else {
                progress.fail(
                    label: "Could not generate report",
                    message: "No samples were recorded in that window."
                )
            }
        }
    }

    private func runRegenerate(id: PersistentIdentifier) {
        progress.startGenerating(label: "Regenerating report…")
        let coordinator = reportCoordinator
        let progress = progress
        Task { @MainActor in
            await coordinator.regenerate(for: id)
            progress.finish(label: "Report regenerated", episodeID: id)
        }
    }

    private func runDelete(id: PersistentIdentifier) {
        let coordinator = reportCoordinator
        Task { await coordinator.delete(episodeID: id) }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                coordinator: coordinator,
                loginItem: loginItem,
                openReport: {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openWindow(id: "report")
                },
                onAdHocReport: { lookback in
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openWindow(id: "report")
                    runAdHoc(lookback: lookback)
                }
            )
            .task {
                await helperGate.evaluate()
                if case .ready = helperGate.state, !samplingStarted {
                    samplingStarted = true
                    coordinator.start()
                    loginItem.registerDefaultIfNeeded()
                }
            }
            .onChange(of: gateReadinessKey) { _, _ in
                if case .ready = helperGate.state, !samplingStarted {
                    samplingStarted = true
                    coordinator.start()
                    loginItem.registerDefaultIfNeeded()
                }
            }
        } label: {
            Image(systemName: "bolt.batteryblock.fill")
        }
        .menuBarExtraStyle(.window)

        Window("Watt — Reports", id: "report") {
            ZStack {
                ReportWindow(
                    coordinator: coordinator,
                    progress: progress,
                    onRecordNote: { note in
                        coordinator.recordUserNote(note)
                    },
                    onRegenerate: { id in
                        runRegenerate(id: id)
                    },
                    onAdHocReport: { lookback in
                        runAdHoc(lookback: lookback)
                    },
                    onDeleteEpisode: { id in
                        runDelete(id: id)
                    }
                )
                .modelContainer(container)
                .disabled(!isReady)

                if !isReady {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    HelperInstallSheet(gate: helperGate)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .shadow(radius: 16)
                }
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Watt") {
                    NSApplication.shared.orderFrontStandardAboutPanel(nil)
                }
            }
        }
    }

    private var isReady: Bool {
        if case .ready = helperGate.state { return true }
        return false
    }

    /// onChange in SwiftUI compares this key — bumping every time the gate
    /// changes phase. We can't compare HelperGate.State directly inside
    /// onChange without making it Equatable across the @Observable boundary.
    private var gateReadinessKey: Int {
        switch helperGate.state {
        case .ready:           return 1
        case .checking:        return 0
        case .needsInstall:    return 2
        case .installing:      return 3
        case .installFailed:   return 4
        }
    }
}
