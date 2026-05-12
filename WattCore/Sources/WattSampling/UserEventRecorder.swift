import AppKit
import Foundation
import IOKit.ps
import WattAnalysis
import WattModels

/// Captures user-observable transitions: app focus changes, plug/unplug,
/// sleep/wake. Each event is dispatched through `onEvent` so the coordinator
/// can persist it; the recorder itself stays state-light.
public final class UserEventRecorder: @unchecked Sendable {
    public typealias Handler = @Sendable (UserEventPoint) -> Void

    private var observers: [NSObjectProtocol] = []
    private var lockObservers: [NSObjectProtocol] = []
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var lastIsCharging: Bool?
    private var lastThermal: Int?
    private var thermalObserver: NSObjectProtocol?
    private var handler: Handler

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public func start() {
        let center = NSWorkspace.shared.notificationCenter

        observers.append(center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.appNotification(note: note, kind: .appActivated)
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.appNotification(note: note, kind: .appLaunched)
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            self?.appNotification(note: note, kind: .appTerminated)
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.dispatch(kind: .systemSleep)
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.dispatch(kind: .systemWake)
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.dispatch(kind: .displaySleep)
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.dispatch(kind: .displayWake)
        })
        lockObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.dispatch(kind: .lockScreen)
        })
        lockObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.dispatch(kind: .unlockScreen)
        })
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.thermalChanged()
        }

        startPowerSourceObserver()
    }

    public func stop() {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for observer in lockObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        observers.removeAll()
        lockObservers.removeAll()
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
        thermalObserver = nil
        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = nil
        }
    }

    public func recordNote(_ text: String) {
        dispatch(kind: .userNote, detail: text)
    }

    private func appNotification(note: Notification, kind: UserEventKind) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        dispatch(
            kind: kind,
            bundleID: app.bundleIdentifier,
            appName: app.localizedName,
            detail: nil
        )
    }

    private func dispatch(
        kind: UserEventKind,
        bundleID: String? = nil,
        appName: String? = nil,
        detail: String? = nil
    ) {
        handler(UserEventPoint(
            timestamp: Date(),
            kind: kind,
            bundleID: bundleID,
            appName: appName,
            detail: detail
        ))
    }

    private func startPowerSourceObserver() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        let source = IOPSNotificationCreateRunLoopSource({ info in
            guard let info else { return }
            let owner = Unmanaged<UserEventRecorder>.fromOpaque(info).takeUnretainedValue()
            owner.powerSourceChanged()
        }, context)?.takeRetainedValue()
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = source
        }
    }

    fileprivate func powerSourceChanged() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return
        }
        for source in list {
            guard let dict = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: AnyObject] else {
                continue
            }
            if (dict[kIOPSTypeKey] as? String) != kIOPSInternalBatteryType { continue }
            let isCharging = (dict[kIOPSIsChargingKey] as? Bool) ?? false
            if lastIsCharging == nil {
                lastIsCharging = isCharging
                continue
            }
            if isCharging != lastIsCharging {
                dispatch(kind: isCharging ? .powerPlugged : .powerUnplugged)
                lastIsCharging = isCharging
            }
            return
        }
    }

    private func thermalChanged() {
        let labels = ["nominal", "fair", "serious", "critical"]
        let raw: Int
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: raw = 0
        case .fair: raw = 1
        case .serious: raw = 2
        case .critical: raw = 3
        @unknown default: raw = 0
        }
        let from = lastThermal.flatMap { labels.indices.contains($0) ? labels[$0] : nil } ?? "unknown"
        let to = labels.indices.contains(raw) ? labels[raw] : "unknown"
        dispatch(kind: .thermalChanged, detail: "\(from) → \(to)")
        lastThermal = raw
    }
}
