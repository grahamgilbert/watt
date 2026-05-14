import AppKit
import SwiftUI
import WattHelperClient
import WattHelperProtocol
import WattUI

/// Runs at process launch (independent of any SwiftUI Scene) and decides
/// whether to surface the helper-install sheet immediately. LSUIElement = YES
/// means the menubar app has no Dock icon and otherwise no foreground UI on
/// launch — without this delegate, the user would never see the gate until
/// they happened to click the menubar item.
@MainActor
public final class WattAppDelegate: NSObject, NSApplicationDelegate {

    public let helperGate: HelperGate
    private var installWindow: NSWindow?

    public override init() {
        self.helperGate = HelperGate(
            expectedProtocolVersion: WattHelperProtocolVersion
        )
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            await self.helperGate.evaluate()
            self.handleGateState()
        }
        // Re-check whenever the gate's state changes, so that after a
        // successful install we tear the window back down.
        observeGate()
    }

    private func observeGate() {
        withObservationTracking {
            _ = self.helperGate.state
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.handleGateState()
                self.observeGate()
            }
        }
    }

    private func handleGateState() {
        switch helperGate.state {
        case .ready:
            installWindow?.close()
            installWindow = nil
        case .checking:
            // First evaluate() call. If we already had a window up (e.g.
            // re-evaluating after a failed install), keep it.
            break
        case .needsInstall, .installing, .installFailed:
            showInstallWindowIfNeeded()
        }
    }

    private func showInstallWindowIfNeeded() {
        if let window = installWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = HelperInstallSheet(gate: helperGate)
            .frame(width: 540, height: 460)
            .background(.regularMaterial)
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable]
        window.title = "Watt — Setup"
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        installWindow = window
    }


}
