import Foundation

/// Throwaway preferences for tests. They live in the temp folder (a full path as the
/// suite name makes macOS store them there), never in ~/Library/Preferences, and each
/// test starts them empty and deletes them afterwards.
public enum ScratchDefaults {
    static func path(_ name: String) -> String { NSTemporaryDirectory() + name }

    public static func make(_ name: String) -> UserDefaults {
        let d = UserDefaults(suiteName: path(name))!
        d.removePersistentDomain(forName: path(name))
        return d
    }

    public static func discard(_ name: String) {
        UserDefaults(suiteName: path(name))?.removePersistentDomain(forName: path(name))
        try? FileManager.default.removeItem(atPath: path(name) + ".plist")
    }
}
