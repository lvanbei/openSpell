import Foundation

/// Where settings and history live: the App Group on iOS (shared by the app and the keyboard),
/// the app's own defaults domain and Application Support folder on macOS.
public enum SharedStorage {
    public static let appGroup = "group.app.openspell"

    public static let defaults: UserDefaults = {
        #if os(iOS)
        UserDefaults(suiteName: appGroup) ?? .standard
        #else
        .standard
        #endif
    }()

    public static let directory: URL = {
        let fm = FileManager.default
        #if os(iOS)
        let base = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #else
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "OpenSpell", directoryHint: .isDirectory)
        #endif
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()
}
