import AppKit
import Sparkle

/// Automatic updates with Sparkle. Active only in builds made with an update
/// feed and signing key (scripts/setup-updates.sh writes both into the app's
/// Info.plist at build time); otherwise "Check for Updates" explains that.
final class Updater: NSObject {
    static let shared = Updater()
    private var controller: SPUStandardUpdaterController?

    /// This build knows where to look for updates and how to verify them.
    var isConfigured: Bool {
        let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    func start() {
        guard isConfigured, ProcessInfo.processInfo.environment["ANSER_SELFTEST"] == nil else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        if let controller { controller.checkForUpdates(sender); return }
        let a = NSAlert()
        a.messageText = "Updates aren't set up for this build"
        a.informativeText = "This copy of Anser was built without an update feed, so it can't check for new versions. Builds made with scripts/release.sh after running scripts/setup-updates.sh update themselves."
        a.runModal()
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }
}
