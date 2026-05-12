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
    @State private var loginItem: LoginItemController
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
        self._loginItem = State(initialValue: LoginItemController())
        self.reportCoordinator = ReportCoordinator(writer: writer)
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
                    Task { await reportCoordinator.generateAdHocReport(lookback: lookback) }
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
                onRecordNote: { note in
                    coordinator.recordUserNote(note)
                },
                onRegenerate: { id in
                    Task { await reportCoordinator.regenerate(for: id) }
                },
                onAdHocReport: { lookback in
                    Task { await reportCoordinator.generateAdHocReport(lookback: lookback) }
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
