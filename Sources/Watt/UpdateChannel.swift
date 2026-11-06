import Foundation

enum UpdateChannel {
    static let prereleasePreference = "Watt.installPrereleases"
    static let checkInterval: TimeInterval = 3600

    static func feedURL(includePrereleases: Bool) -> URL {
        URL(string: "https://raw.githubusercontent.com/grahamgilbert/watt/main/" +
            (includePrereleases ? "appcast-prerelease.xml" : "appcast.xml"))!
    }
}
