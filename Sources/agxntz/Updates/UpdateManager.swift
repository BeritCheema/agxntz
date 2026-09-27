import AppKit
import Combine
import Sparkle

/// Owns Sparkle. The update feed (appcast.xml) and the update archive both come
/// straight from the GitHub release — see SUFeedURL in Info.plist.
///
/// agxntz is a menu-bar (LSUIElement) app, so scheduled checks use Sparkle's
/// "gentle reminders": when a background check finds an update, Sparkle does not
/// pop a window over whatever the user is doing. Instead `pendingVersion` is set
/// and our own UI (dropdown row, right-click menu, Settings) offers the update;
/// clicking it hands back to Sparkle, which shows its install prompt.
@MainActor
final class UpdateManager: NSObject, ObservableObject {
    static let shared = UpdateManager()

    /// Version of an update found by a background check, awaiting the user.
    @Published private(set) var pendingVersion: String?

    /// Mirrors Sparkle's own "check automatically" preference.
    @Published var automaticallyChecks = false {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != automaticallyChecks else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecks
        }
    }

    private var controller: SPUStandardUpdaterController?

    /// False for local dev builds (not a stamped release), where update checks
    /// would compare against a meaningless version.
    var isEnabled: Bool { controller != nil }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Whether this build should run the updater: a real release bundle (has a
    /// feed URL and a stamped version), or forced on for testing.
    static var shouldRun: Bool {
        if ProcessInfo.processInfo.environment["AGXNTZ_FORCE_UPDATER"] == "1" { return true }
        let hasFeed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
        return hasFeed && currentVersion != "dev"
    }

    func start() {
        guard controller == nil, Self.shouldRun else {
            Log.d("updater: disabled for this build (version \(Self.currentVersion))")
            return
        }
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        controller = c
        automaticallyChecks = c.updater.automaticallyChecksForUpdates
        Log.d("updater: started, automatic checks \(automaticallyChecks)")
    }

    /// User-initiated check. If a background check already found an update, this
    /// shows it; otherwise Sparkle checks now and reports the result.
    func checkForUpdates() {
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true) // accessory app: bring Sparkle's window forward
        controller.checkForUpdates(nil)
    }
}

extension UpdateManager: SPUUpdaterDelegate {
    /// Test hook: AGXNTZ_FEED_URL points the updater at a local appcast. Releases
    /// use SUFeedURL (the GitHub release's appcast.xml).
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["AGXNTZ_FEED_URL"]
    }
}

// Sparkle calls these on the main thread; they're nonisolated only to satisfy
// the Objective-C protocol, so hop into main-actor isolation explicitly.
extension UpdateManager: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Only let Sparkle show its window right away if the check happened just
        // as the app launched / was engaged; otherwise we surface it gently.
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        Log.d("updater: found \(version) (\(handleShowingUpdate ? "Sparkle shows it" : "gentle reminder"))")
        MainActor.assumeIsolated {
            if handleShowingUpdate {
                // An accessory (menu-bar) app isn't activated on its own, so
                // Sparkle's window would open behind other apps' windows.
                NSApp.activate(ignoringOtherApps: true)
            } else {
                self.pendingVersion = version
            }
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { self.pendingVersion = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { self.pendingVersion = nil }
    }
}
