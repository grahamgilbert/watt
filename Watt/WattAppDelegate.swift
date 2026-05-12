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
        Task { @MainActor in
            // Poll the gate's state at 0.5s intervals while a non-ready state
            // is showing. We could use Combine or an Observable bridge, but
            // a tiny poll loop is the simplest correct thing for a one-shot
            // launch flow.
            var lastKey = -1
            while !Task.isCancelled {
                let key = self.gateKey(self.helperGate.state)
                if key != lastKey {
                    lastKey = key
                    self.handleGateState()
                }
                try? await Task.sleep(for: .milliseconds(500))
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

    private func gateKey(_ state: HelperGate.State) -> Int {
        switch state {
        case .checking:        return 0
        case .ready:           return 1
        case .needsInstall:    return 2
        case .installing:      return 3
        case .installFailed:   return 4
        }
    }
}
