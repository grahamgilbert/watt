import Foundation
import SwiftData

public enum UserEventKind: String, Codable, Sendable, CaseIterable {
    case appActivated
    case appLaunched
    case appTerminated
    case powerPlugged
    case powerUnplugged
    case displaySleep
    case displayWake
    case systemSleep
    case systemWake
    case lockScreen
    case unlockScreen
    case thermalChanged
    case userNote
}

@Model
public final class UserEvent {
    @Attribute(.unique) public var id: UUID
    public var timestamp: Date
    public var kindRaw: String
    public var bundleID: String?
    public var appName: String?
    public var detail: String?

    public var kind: UserEventKind {
        get { UserEventKind(rawValue: kindRaw) ?? .userNote }
        set { kindRaw = newValue.rawValue }
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        kind: UserEventKind,
        bundleID: String? = nil,
        appName: String? = nil,
        detail: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kindRaw = kind.rawValue
        self.bundleID = bundleID
        self.appName = appName
        self.detail = detail
    }
}
