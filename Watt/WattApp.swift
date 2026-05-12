import SwiftData
import SwiftUI
import WattAI
import WattAnalysis
import WattHelperClient
import WattModels
import WattSampling
import WattUI

@main
struct WattApp: App {
    @Environment(\.openWindow) private var openWindow
    private let container: ModelContainer
    @State private var coordinator: SamplingCoordinator
    private let reportCoordinator: ReportCoordinator
    private let helperClient = HelperClient()

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
        self.reportCoordinator = ReportCoordinator(writer: writer)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(coordinator: coordinator) {
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "report")
            }
            .task { coordinator.start() }
        } label: {
            Image(systemName: "bolt.batteryblock.fill")
        }
        .menuBarExtraStyle(.window)

        Window("Watt — Reports", id: "report") {
            ReportWindow(
                coordinator: coordinator,
                onRecordNote: { note in
                    coordinator.recordUserNote(note)
                },
                onRegenerate: { id in
                    Task { await reportCoordinator.regenerate(for: id) }
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
