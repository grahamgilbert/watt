import SwiftData
import SwiftUI
import WattAI
import WattAnalysis
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
                coordinator.start()
                loginItem.registerDefaultIfNeeded()
            }
        } label: {
            Image(systemName: "bolt.batteryblock.fill")
        }
        .menuBarExtraStyle(.window)

        Window("Watt — Reports", id: "report") {
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
}
