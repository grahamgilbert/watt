import AppKit
import Sparkle
import SwiftUI

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published var automaticallyChecksForUpdates = true {
        didSet {
            guard oldValue != automaticallyChecksForUpdates else { return }
            controller?.updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }
    @Published var includePrereleases = UserDefaults.standard.bool(forKey: UpdateChannel.prereleasePreference) {
        didSet {
            UserDefaults.standard.set(includePrereleases, forKey: UpdateChannel.prereleasePreference)
            if oldValue != includePrereleases { controller?.updater.resetUpdateCycleAfterShortDelay() }
        }
    }
    private var controller: SPUStandardUpdaterController?
    private var observations: [NSKeyValueObservation] = []

    init(startingUpdater: Bool = true) {
        super.init()
        guard startingUpdater else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        automaticallyChecksForUpdates = controller.updater.automaticallyChecksForUpdates
        observations.append(controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.canCheckForUpdates = value }
        })
        observations.append(controller.updater.observe(\.lastUpdateCheckDate, options: [.initial, .new]) { [weak self] _, change in
            let value = change.newValue ?? nil
            Task { @MainActor in self?.lastUpdateCheckDate = value }
        })
        observations.append(controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.automaticallyChecksForUpdates = value }
        })
        controller.startUpdater()
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UpdateChannel.feedURL(includePrereleases: UserDefaults.standard.bool(forKey: UpdateChannel.prereleasePreference)).absoluteString
    }

    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller?.checkForUpdates(nil)
    }
}

struct UpdateControls: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Check automatically every hour", isOn: $updater.automaticallyChecksForUpdates)
            Toggle("Include prerelease versions", isOn: $updater.includePrereleases)
            HStack {
                Button("Check for Updates…", action: updater.checkForUpdates)
                    .disabled(!updater.canCheckForUpdates)
                Spacer()
                if let date = updater.lastUpdateCheckDate {
                    Text("Last checked: \(date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
    }
}
