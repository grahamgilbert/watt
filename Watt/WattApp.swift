import SwiftData
import SwiftUI
import UserNotifications
import WattAI
import WattAnalysis
import WattHelperClient
import WattHelperProtocol
import WattModels
import WattSampling
import WattUI

@main
struct WattApp: App {
    @NSApplicationDelegateAdaptor(WattAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    private let container: ModelContainer
    @State private var coordinator: SamplingCoordinator
    @State private var loginItem: LoginItemController
    @State private var progress: ReportProgress
    @State private var prefs: WattPreferences
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
        self._prefs = State(initialValue: WattPreferences())
        self.reportCoordinator = ReportCoordinator(writer: writer)
    }

    private func runAdHoc(lookback: TimeInterval) {
        let label = "Generating report for the last \(Int(lookback / 60)) min…"
        progress.startGenerating(label: label)
        let coordinator = reportCoordinator
        let progress = progress
        Task.detached {
            let id = await coordinator.generateAdHocReport(lookback: lookback)
            await MainActor.run {
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
    }

    private func runRegenerate(id: PersistentIdentifier) {
        progress.startGenerating(label: "Regenerating report…")
        let coordinator = reportCoordinator
        let progress = progress
        Task.detached {
            await coordinator.regenerate(for: id)
            await MainActor.run {
                progress.finish(label: "Report regenerated", episodeID: id)
            }
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
            .onChange(of: gateReadinessKey) { _, _ in
                startSamplingIfReady()
            }
            // Catch the case where the gate is already .ready before the
            // MenuBarExtra view renders (helper was alive at launch and ping
            // succeeded immediately — .task fires too late).
            .task {
                startSamplingIfReady()
                // Also poll once after a short delay in case the state
                // transition races the view appearing.
                try? await Task.sleep(for: .seconds(1))
                startSamplingIfReady()
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
                },
                onDeleteReport: { reportID, episodeStartedAt in
                    Task { await reportCoordinator.deleteReport(reportID: reportID, episodeStartedAt: episodeStartedAt) }
                }
            )
            .modelContainer(container)
            .disabled(!isReady)
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

        Settings {
            PreferencesView(prefs: prefs, loginItem: loginItem)
        }
    }

    private func startSamplingIfReady() {
        guard case .ready = appDelegate.helperGate.state, !samplingStarted else { return }
        samplingStarted = true
        coordinator.onEpisodeReady = { [self] id in
            Task.detached {
                let ok = await self.reportCoordinator.generateReport(for: id)
                if ok {
                    await self.sendEpisodeNotification(episodeID: id)
                }
            }
        }
        coordinator.start()
        loginItem.registerDefaultIfNeeded()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendEpisodeNotification(episodeID: PersistentIdentifier) async {
        guard prefs.notifyOnEpisodeReady else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "Watt — High energy episode detected"
        content.body = "A report is ready. Click to open."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "watt.episode.\(episodeID.hashValue)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private var isReady: Bool {
        if case .ready = appDelegate.helperGate.state { return true }
        return false
    }

    private var gateReadinessKey: Int {
        switch appDelegate.helperGate.state {
        case .ready:           return 1
        case .checking:        return 0
        case .needsInstall:    return 2
        case .installing:      return 3
        case .installFailed:   return 4
        }
    }
}
